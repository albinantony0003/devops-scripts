import https from 'https';
import crypto from 'crypto';
import { CloudWatchClient, GetMetricWidgetImageCommand } from "@aws-sdk/client-cloudwatch";
import { DynamoDBClient } from "@aws-sdk/client-dynamodb";
import { DynamoDBDocumentClient, PutCommand, GetCommand } from "@aws-sdk/lib-dynamodb";

// ====================================================
// ⚙️ CONFIGURATION & INITIALIZATION
// ====================================================
const region = process.env.AWS_REGION || "us-east-1";
const cwClient = new CloudWatchClient({ region });
const docClient = DynamoDBDocumentClient.from(new DynamoDBClient({ region }));

const SLACK_SIGNING_SECRET = process.env.SLACK_SIGNING_SECRET;

// Build the escalation dropdown dynamically
const ESCALATION_GROUPS = [
    { text: "DevOps L2", value: process.env.DEVOPS_L2_GROUP_ID },
    { text: "DevOps L3", value: process.env.DEVOPS_L3_GROUP_ID },
    { text: "Developers", value: process.env.DEVS_GROUP_ID }
].filter(group => group.value);

/**
 * 🚀 MAIN LAMBDA HANDLER
 * Processes incoming webhook events from Slack (Interactions) and SNS (CloudWatch Alarms).
 */
export const handler = async function (event, context) {
    // 🚀 DYNAMIC FEATURE FLAGS: Evaluated per-invocation to avoid warm-container caching
    const NOISE_SUPPRESSION_ENABLED = ['yes', 'true'].includes((process.env.NOISE_SUPPRESSION || '').toLowerCase());
    const NOISE_SUPPRESSION_DB = process.env.NOISE_SUPPRESSION_DB;
    const NOISE_SUPPRESSION_WINDOW = parseInt(process.env.NOISE_SUPPRESSION_WINDOW || "240", 10);

    // Safely extract the body, handling API Gateway Base64 encoding if present
    const rawBody = event.isBase64Encoded
        ? Buffer.from(event.body, 'base64').toString('utf-8')
        : event.body;

    // Slack security headers
    const signature = event.headers?.['x-slack-signature'] || event.headers?.['X-Slack-Signature'];
    const timestamp = event.headers?.['x-slack-request-timestamp'] || event.headers?.['X-Slack-Request-Timestamp'];

    // ====================================================
    // 🛑 MODE 1: SLACK INTERACTIONS (Button Clicks)
    // ====================================================
    if (signature && timestamp) {
        if (!verifySlackSignature(SLACK_SIGNING_SECRET, rawBody, timestamp, signature)) {
            console.error(JSON.stringify({
                level: "ERROR", event: "auth_failure", message: "Invalid Slack signature. Request rejected to prevent unauthorized access."
            }));
            return { statusCode: 401, body: "Unauthorized" };
        }

        try {
            const params = new URLSearchParams(rawBody);
            const payload = JSON.parse(params.get('payload'));

            const action = payload.actions[0];
            const actionId = action.action_id;
            const userId = payload.user.id;

            // --- HANDLER: ACKNOWLEDGE / MUTE ---
            if (actionId === 'ack_action') {
                const alarmName = action.value;
                const blocks = payload.message.attachments?.[0]?.blocks || payload.message.blocks || [];

                // SMART GUARD: Prevent double-acking
                if (blocks.some(b => b.type === 'context' && b.elements?.[0]?.text?.includes('✅ Acknowledged'))) {
                    console.log(JSON.stringify({ level: "INFO", event: "duplicate_ack_ignored", alarmName, userId }));
                    return { statusCode: 200, body: "OK" };
                }

                // FEATURE FLAG CHECK: Write to DynamoDB if suppression is enabled
                if (NOISE_SUPPRESSION_ENABLED && NOISE_SUPPRESSION_DB && alarmName) {
                    const expiration = Math.floor(Date.now() / 1000) + (NOISE_SUPPRESSION_WINDOW * 60);

                    console.log(JSON.stringify({
                        level: "INFO", event: "alarm_muted", message: `Alarm muted for ${NOISE_SUPPRESSION_WINDOW}m.`, alarmName, userId, expiresAtEpoch: expiration
                    }));

                    await docClient.send(new PutCommand({
                        TableName: NOISE_SUPPRESSION_DB,
                        Item: { AlarmName: alarmName, AcknowledgedBy: userId, TTL: expiration }
                    }));
                } else {
                    console.log(JSON.stringify({ level: "INFO", event: "alarm_acknowledged", alarmName, userId }));
                }

                // Remove the "Ack" button from the Slack UI
                const actionBlock = blocks.find((b) => b.type === "actions");
                if (actionBlock) {
                    actionBlock.elements = actionBlock.elements.filter(
                        (el) => el.action_id !== "ack_action",
                    );
                }

                // Get the exact time of the acknowledgment
                const ackTime = new Date().toLocaleTimeString('en-US', { timeZone: 'UTC' }) + ' UTC';

                // SMART UI: Success message with timestamp
                const successText = NOISE_SUPPRESSION_ENABLED
                    ? `*✅ Acknowledged by <@${userId}> at ${ackTime} — duplicate alerts suppressed for ${NOISE_SUPPRESSION_WINDOW}m*`
                    : `*✅ Acknowledged by <@${userId}> at ${ackTime}*`;

                blocks.push({ "type": "context", "elements": [{ "type": "mrkdwn", "text": successText }] });

                // Update the original message in Slack
                await sendToSlackWebhook(payload.response_url, { attachments: [{ color: "#ccc", blocks: blocks }], replace_original: true });
            }

            // --- HANDLER: ESCALATION ---
            if (actionId === 'escalate_action') {
                const groupId = action.selected_option?.value;
                if (!groupId) return { statusCode: 200, body: "OK" };

                const isUser = groupId.startsWith('U') || groupId.startsWith('W');
                const tag = isUser ? `<@${groupId}>` : `<!subteam^${groupId}>`;
                const localTime = new Date().toLocaleTimeString('en-US', { timeZone: 'UTC' }) + ' UTC';

                console.log(JSON.stringify({ level: "INFO", event: "escalation_triggered", target: groupId, userId }));

                await postSlackAPI('chat.postMessage', {
                    channel: payload.channel.id,
                    thread_ts: payload.message.ts,
                    text: `🚨 Escalation Alert`,
                    blocks: [
                        { "type": "context", "elements": [{ "type": "mrkdwn", "text": `*Incident Update* • ${localTime}` }] },
                        { "type": "section", "text": { "type": "mrkdwn", "text": `🚒 *Escalated to ${tag}* by <@${userId}>` } }
                    ]
                });
            }

            return { statusCode: 200, body: "OK" };
        } catch (e) {
            console.error(JSON.stringify({ level: "ERROR", event: "interaction_error", errorDetail: e.message }));
            return { statusCode: 500 };
        }
    }

    // ====================================================
    // 🚨 MODE 2: CLOUDWATCH ALARM NOTIFICATIONS (SNS)
    // ====================================================
    try {
        const snsRecord = event.Records?.[0]?.Sns;
        if (!snsRecord) {
            console.warn(JSON.stringify({ level: "WARN", event: "invalid_invocation", message: "No SNS Record." }));
            return { statusCode: 400, body: "No SNS Record" };
        }

        const messageData = safeParse(snsRecord.Message);
        const alarmName = messageData.AlarmName || "AWS Alarm";

        // We strictly ignore 'OK' states to prevent flap-noise
        if (messageData.NewStateValue === "OK") {
            console.log(JSON.stringify({ level: "INFO", event: "ok_state_ignored", alarmName }));
            return { statusCode: 200, body: "OK Ignored" };
        }

        // FEATURE FLAG CHECK: Check DynamoDB if suppression is turned on
        if (NOISE_SUPPRESSION_ENABLED && NOISE_SUPPRESSION_DB) {
            const getRes = await docClient.send(new GetCommand({
                TableName: NOISE_SUPPRESSION_DB,
                Key: { AlarmName: alarmName }
            }));

            if (getRes.Item && getRes.Item.TTL > Math.floor(Date.now() / 1000)) {
                console.log(JSON.stringify({ level: "INFO", event: "alarm_suppressed", alarmName, expiresAtEpoch: getRes.Item.TTL }));
                return { statusCode: 200, body: "Muted" };
            }
        }

        console.log(JSON.stringify({ level: "INFO", event: "processing_new_alarm", alarmName }));

        // --- PREPARE SLACK PAYLOAD ---
        const alarmRegion = snsRecord.TopicArn.split(":")[3] || region;
        const alarmUrl = `https://${alarmRegion}.console.aws.amazon.com/cloudwatch/home?region=${alarmRegion}#alarmsV2:alarm/${encodeURIComponent(alarmName)}`;
        const accountId = messageData.AWSAccountId || "Unknown";

        // SMART UI: Button text
        const buttonText = NOISE_SUPPRESSION_ENABLED ? "✋ Ack & Mute" : "✋ Ack";

        const actionElements = [
            { "type": "button", "text": { "type": "plain_text", "text": buttonText }, "action_id": "ack_action", "value": alarmName, "style": "primary" }
        ];

        if (ESCALATION_GROUPS.length > 0) {
            actionElements.push({
                "type": "static_select",
                "placeholder": { "type": "plain_text", "text": "Escalate..." },
                "action_id": "escalate_action",
                "options": ESCALATION_GROUPS.map(g => ({ "text": { "type": "plain_text", "text": g.text }, "value": g.value }))
            });
        }

        // 1. Post the parent message (High-level summary)
        const parentResponse = await postSlackAPI('chat.postMessage', {
            channel: process.env.SLACK_CHANNEL,
            attachments: [{
                fallback: `🚨 ${alarmName}`, // 🚀 FIX: Hidden text used ONLY for push notifications/lock screens
                color: "#FF0000",
                blocks: [
                    { "type": "section", "text": { "type": "mrkdwn", "text": `*🚨 <${alarmUrl}|${alarmName}>*` } },
                    { "type": "actions", "elements": actionElements }
                ]
            }]
        });

        // 2. Post the thread reply (Detailed reasons)
        const localTime = new Date().toLocaleTimeString('en-US', { timeZone: 'UTC' }) + ' UTC';
        await postSlackAPI('chat.postMessage', {
            channel: parentResponse.channel,
            thread_ts: parentResponse.ts,
            blocks: [{
                "type": "section",
                "text": { "type": "mrkdwn", "text": `🔍 *Alarm Details*\n• *Time:* \`${localTime}\`\n• *Account:* \`${accountId}\`\n• *Reason:* \`${messageData.NewStateReason || "N/A"}\`\n• *Description:* \`${messageData.AlarmDescription || "N/A"}\`` }
            }]
        });

        // 3. Generate and upload the CloudWatch Graph to the thread
        if (messageData.Trigger?.Metrics) {
            try {
                const widgetJson = buildWidgetJson(messageData.Trigger, alarmRegion, messageData.StateChangeTime);
                const graphData = await cwClient.send(new GetMetricWidgetImageCommand({
                    MetricWidget: JSON.stringify(widgetJson), OutputFormat: "png"
                }));

                await uploadFileToSlackV2(
                    parentResponse.channel, parentResponse.ts, Buffer.from(graphData.MetricWidgetImage), "📈 CloudWatch Metric Graph"
                );

                console.log(JSON.stringify({ level: "INFO", event: "graph_uploaded", alarmName }));
            } catch (gErr) {
                console.error(JSON.stringify({ level: "ERROR", event: "graph_failure", errorDetail: gErr.message }));
            }
        }

        return { statusCode: 200, body: "Processed" };
    } catch (error) {
        console.error(JSON.stringify({ level: "ERROR", event: "handler_error", errorDetail: error.message }));
        throw error;
    }
};

// ====================================================
// 🛠️ UTILITY HELPERS
// ====================================================

function verifySlackSignature(signingSecret, rawBody, timestamp, signature) {
    if (!signingSecret || !timestamp || !signature) return false;
    if (Math.abs(Date.now() / 1000 - parseInt(timestamp, 10)) > 300) return false;

    const hmac = crypto.createHmac('sha256', signingSecret).update(`v0:${timestamp}:${rawBody}`).digest('hex');
    const expectedBuf = Buffer.from(`v0=${hmac}`);
    const signatureBuf = Buffer.from(signature);

    if (expectedBuf.length !== signatureBuf.length) return false;
    try { return crypto.timingSafeEqual(expectedBuf, signatureBuf); } catch { return false; }
}

function safeParse(str) {
    try { return JSON.parse(str); }
    catch (e) { console.error(JSON.stringify({ level: "ERROR", event: "parse_error", errorDetail: e.message })); return {}; }
}

function httpRequest(options, data) {
    return new Promise((resolve, reject) => {
        const req = https.request(options, (res) => {
            let body = '';
            res.on('data', chunk => body += chunk);
            res.on('end', () => resolve({ statusCode: res.statusCode, headers: res.headers, body }));
        });
        req.on('error', reject);
        if (data) req.write(data);
        req.end();
    });
}

async function postSlackAPI(endpoint, data, retryCount = 0) {
    const options = {
        hostname: 'slack.com', path: `/api/${endpoint}`, method: 'POST',
        headers: { 'Content-Type': 'application/json', 'Authorization': `Bearer ${process.env.SLACK_BOT_TOKEN}` }
    };

    const response = await httpRequest(options, JSON.stringify(data));
    const parsed = JSON.parse(response.body);

    if (!parsed.ok) {
        if (parsed.error === 'ratelimited' && retryCount < 1) {
            const delay = parseInt(response.headers['retry-after'] || '1', 10) * 1000;
            console.warn(JSON.stringify({ level: "WARN", event: "slack_ratelimit", endpoint, delayMs: delay }));
            await new Promise(r => setTimeout(r, delay));
            return postSlackAPI(endpoint, data, retryCount + 1);
        }
        throw new Error(`Slack API Error [${endpoint}]: ${parsed.error}`);
    }
    return parsed;
}

async function uploadFileToSlackV2(channelId, threadTs, imageBuffer, title) {
    const getUrlBody = `filename=graph.png&length=${imageBuffer.length}`;
    const step1Options = {
        hostname: 'slack.com', path: '/api/files.getUploadURLExternal', method: 'POST',
        headers: { 'Authorization': `Bearer ${process.env.SLACK_BOT_TOKEN}`, 'Content-Type': 'application/x-www-form-urlencoded', 'Content-Length': Buffer.byteLength(getUrlBody) }
    };
    const step1Response = await httpRequest(step1Options, getUrlBody);
    const step1Data = JSON.parse(step1Response.body);
    if (!step1Data.ok) throw new Error(`Slack upload URL failed: ${step1Data.error}`);

    const uploadUrl = new URL(step1Data.upload_url);
    const step2Options = {
        hostname: uploadUrl.hostname, path: uploadUrl.pathname + uploadUrl.search, method: 'POST',
        headers: { 'Content-Type': 'application/octet-stream', 'Content-Length': imageBuffer.length }
    };
    await httpRequest(step2Options, imageBuffer);

    const completeBody = JSON.stringify({ channel_id: channelId, thread_ts: threadTs, initial_comment: title, files: [{ id: step1Data.file_id }] });
    const step3Options = {
        hostname: 'slack.com', path: '/api/files.completeUploadExternal', method: 'POST',
        headers: { 'Authorization': `Bearer ${process.env.SLACK_BOT_TOKEN}`, 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(completeBody) }
    };

    const step3Response = await httpRequest(step3Options, completeBody);
    const step3Data = JSON.parse(step3Response.body);
    if (!step3Data.ok) throw new Error(`Slack completion failed: ${step3Data.error}`);
    return step3Data;
}

async function sendToSlackWebhook(url, data) {
    const parsedUrl = new URL(url);
    const options = { method: 'POST', headers: { 'Content-Type': 'application/json' }, hostname: parsedUrl.hostname, path: parsedUrl.pathname + parsedUrl.search };
    const response = await httpRequest(options, JSON.stringify(data));
    if (response.statusCode >= 400) throw new Error(`Webhook Failed: ${response.statusCode} ${response.body}`);
    return response.body;
}

function buildWidgetJson(trigger, region, alarmTimeStr) {
    const metrics = [];
    for (const m of trigger.Metrics) {
        if (m.Expression) {
            metrics.push([{ expression: m.Expression, id: m.Id, label: m.Label, visible: m.ReturnData }]);
        } else if (m.MetricStat) {
            const met = m.MetricStat.Metric;
            const row = [met.Namespace, met.MetricName];
            if (met.Dimensions) for (const dim of met.Dimensions) row.push(dim.name, dim.value);
            row.push({ stat: m.MetricStat.Stat, period: m.MetricStat.Period, id: m.Id, visible: m.ReturnData });
            metrics.push(row);
        }
    }
    const aTime = alarmTimeStr ? new Date(alarmTimeStr) : new Date();
    const startTime = new Date(aTime.getTime() - (2.5 * 60 * 60 * 1000));
    const endTime = new Date(aTime.getTime() + (0.5 * 60 * 60 * 1000));
    return {
        view: "timeSeries", stacked: false, metrics: metrics, region: region, width: 800, height: 400,
        start: startTime.toISOString(), end: endTime.toISOString(),
        annotations: { horizontal: [{ value: trigger.Threshold, label: "Threshold", color: "#d62728" }] }
    };
}
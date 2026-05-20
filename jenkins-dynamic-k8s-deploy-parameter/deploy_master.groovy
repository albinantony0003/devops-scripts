import groovy.json.*
import jenkins.model.*

/**
 * Queries the Kubernetes cluster to find the currently running image tag for a deployment.
 *
 * @param deployName The name of the Kubernetes Deployment
 * @param ns The namespace of the Deployment
 * @param kPath The absolute path to the kubectl executable
 * @param configPath The absolute path to the kubeconfig file
 * @return The tag (string) if found, otherwise null
 */
def getLiveTag(deployName, ns, kPath, configPath) {
    try {
        def cmd = "${kPath} --kubeconfig ${configPath} get deployment ${deployName} -n ${ns} -o jsonpath={.spec.template.spec.containers[0].image}"
        def process = cmd.execute()
        def out = new StringBuilder(), err = new StringBuilder()
        process.waitForProcessOutput(out, err)
        if (process.exitValue() == 0) {
            def fullImage = out.toString().trim()
            return fullImage.contains(":") ? fullImage.split(":")[-1] : null
        }
    } catch (Exception e) { 
        return null 
    }
    return null
}

/**
 * Renders an HTML row consisting of a checkbox and a dropdown populated with available image tags.
 * The active tag currently running in the Kubernetes cluster is auto-selected and highlighted.
 *
 * @param cfg Map containing keys:
 *            - imageName: Docker repository image path (e.g. "library/nginx")
 *            - deployName: K8s Deployment name
 *            - namespace: K8s Namespace
 *            - credsId: Jenkins credentials ID for Docker Registry auth
 *            - kubectlPath: Path to kubectl binary
 *            - kubeconfigPath: Path to Kubeconfig file
 * @return HTML string representing a parameter selection UI row
 */
def render(Map cfg) {
    try {
        // 1. Fetch Credentials from Jenkins Credential Store
        def jenkinsCredentials = com.cloudbees.plugins.credentials.CredentialsProvider.lookupCredentials(
            com.cloudbees.plugins.credentials.Credentials.class, Jenkins.instance, null, null
        )
        def c = jenkinsCredentials.find { it.id == cfg.credsId }
        if (!c) return "<b style='color:red;'>Missing Creds: ${cfg.credsId}</b>"

        def user = c.username
        def pass = c.password.getPlainText()

        // 2. Get Cluster State (Find current running tag)
        def liveTag = getLiveTag(cfg.deployName, cfg.namespace, cfg.kubectlPath, cfg.kubeconfigPath)

        // 3. Registry Fetching (Docker Hub Registry v2 API)
        def authUrl = new URL("https://auth.docker.io/token?service=registry.docker.io&scope=repository:${cfg.imageName}:pull")
        def authConn = authUrl.openConnection()
        def authHeader = "${user}:${pass}".bytes.encodeBase64().toString()
        authConn.setRequestProperty("Authorization", "Basic ${authHeader}")

        def authResult = new JsonSlurper().parseText(authConn.content.text)
        def token = authResult.token

        // Fetch up to 1000 tags from the Docker Registry
        def tagsUrl = new URL("https://registry-1.docker.io/v2/${cfg.imageName}/tags/list?n=1000")
        def tagsConn = tagsUrl.openConnection()
        tagsConn.setRequestProperty("Authorization", "Bearer ${token}")

        def tagsResult = new JsonSlurper().parseText(tagsConn.content.text)
        def allTags = tagsResult.tags ?: []

        // Sort tags (latest at the top, others in reverse alphabetical order)
        def sortedTags = allTags.sort { a, b ->
            if (a == 'latest') return -1
            if (b == 'latest') return 1
            return b <=> a
        }

        // Limit dropdown size to top 100 tags to keep Jenkins UI responsive
        def tagList = sortedTags.take(100)

        // --- THE FIX: ALWAYS START UNCHECKED ---
        def isChecked = ""
        // ---------------------------------------

        def tagOptions = ""

        // Ensure the active live cluster tag is included in the options list even if it is old
        if (liveTag && !tagList.contains(liveTag)) {
            tagList.add(0, liveTag)
        }

        tagList.each { tag ->
            def selected = (tag == liveTag) ? "selected" : ""
            def label = (tag == liveTag) ? "⭐ ${tag} (LIVE)" : tag
            tagOptions += "<option value='${tag}' ${selected}>${label}</option>\n"
        }

        return """
        <div style="font-family: Arial, sans-serif; margin-bottom: 5px;">
            <table border="1" cellpadding="8" cellspacing="0" style="border-collapse: collapse; min-width: 550px; border: 1px solid #bbb;">
                <tr style="background-color: #fff;">
                    <td style="font-weight: bold; width: 280px;">
                        <input type="checkbox" name="value" value="Yes" ${isChecked} id="check_${cfg.imageName}" style="vertical-align: middle;">
                        <label for="check_${cfg.imageName}" style="cursor: pointer; margin-left: 5px; vertical-align: middle;">${cfg.imageName}</label>
                    </td>
                    <td style="width: 250px;">
                        <select name="value" style="width: 100%; padding: 4px; border: 1px solid #999;">
                            ${tagOptions}
                        </select>
                    </td>
                </tr>
            </table>
            <div style="margin-top: 5px; margin-left: 2px; font-size: 11px; color: #555;">
                <img src="/static/72793282/images/16x16/document_edit.png" style="vertical-align: middle; width: 12px; height: 12px; margin-right: 4px;">
                Found <b>${allTags.size()}</b> total tags |
                <span style="color: ${liveTag ? '#28a745' : '#d9534f'}; font-weight: bold;">
                    ${liveTag ? "Current in Cluster: " + liveTag : "Not found in Cluster"}
                </span>
            </div>
        </div>
        <hr style="margin: 15px 0; border: 0; border-top: 1px solid #ccc; width: 100%;">
        """
    } catch (Exception e) {
        return "<div style='color:red;'><b>Registry Error:</b> ${e.message}</div>"
    }
}

return this

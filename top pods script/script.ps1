$NAMESPACE = "namespace"
$SELECTOR  = "app=app"
$INTERVAL  = 10
$OUTPUT_FILE = "warmup_profile_$(Get-Date -Format 'yyyyMMdd_HHmmss').csv"

"timestamp,pod,cpu_millicores,delta_m,trend,age_seconds,status" | Tee-Object -FilePath $OUTPUT_FILE
Write-Host "Watching for new pods in $NAMESPACE..." -ForegroundColor Cyan

$podStartTimes = @{}
$podLastCPU    = @{}

while ($true) {
    $pods = kubectl get pods -n $NAMESPACE -l $SELECTOR --no-headers 2>$null

    foreach ($line in $pods) {
        $parts  = $line -split '\s+'
        $POD    = $parts[0]
        $STATUS = $parts[2]

        if (-not $podStartTimes.ContainsKey($POD)) {
            $podStartTimes[$POD] = [int](Get-Date -UFormat %s)
            $podLastCPU[$POD]    = 0
            Write-Host "`n>>> New pod detected: $POD" -ForegroundColor Yellow
        }

        $AGE = [int](Get-Date -UFormat %s) - $podStartTimes[$POD]

        if ($AGE -le 300) {
            $topOutput = kubectl top pod $POD -n $NAMESPACE --no-headers 2>$null
            if ($topOutput) {
                $CPU_RAW = ($topOutput -split '\s+')[1]          # e.g. "920m"
                $CPU_M   = [int]($CPU_RAW -replace 'm','')       # numeric millicores

                $LAST    = $podLastCPU[$POD]
                $DELTA   = $CPU_M - $LAST
                $TREND   = if ($DELTA -gt 20) { "↑" } elseif ($DELTA -lt -20) { "↓" } else { "→" }
                $podLastCPU[$POD] = $CPU_M

                $TIMESTAMP = Get-Date -Format "HH:mm:ss"

                # Color by CPU level
                $COLOR = if ($CPU_M -gt 500)     { "Red" }
                    elseif ($CPU_M -gt 100)  { "Yellow" }
                    else                     { "Green" }

                Write-Host ("{0}  age={1,4}s  cpu={2,6}m  delta={3,6}m  {4}  {5}" -f `
                    $TIMESTAMP, $AGE, $CPU_M, $DELTA, $TREND, $STATUS) -ForegroundColor $COLOR

                "$TIMESTAMP,$POD,$CPU_M,$DELTA,$TREND,$AGE,$STATUS" | 
                    Tee-Object -FilePath $OUTPUT_FILE -Append
            }
        }
    }

    Start-Sleep -Seconds $INTERVAL
}
<#
.SYNOPSIS
    Recursively searches for Kubernetes Deployment YAML/YML files and extracts their readiness probe paths.
.DESCRIPTION
    This script searches the current directory (or a specified directory) recursively for YAML/YML files.
    It identifies files containing Kubernetes Deployments and extracts their name and the configured
    readiness probe HTTP path.
.PARAMETER Path
    The root path to search for YAML/YML files. Defaults to the current working directory.
.OUTPUTS
    [PSCustomObject] containing the Folder name, Deployment name, and Readiness Path.
.EXAMPLE
    .\get-readiness-probes.ps1
.EXAMPLE
    .\get-readiness-probes.ps1 -Path C:\projects\k8s-configs
#>
param(
    [string]$Path = "."
)

Get-ChildItem -Path $Path -Recurse -Include *.yaml, *.yml | ForEach-Object {
    $file = $_
    $content = Get-Content $file.FullName
    
    # Check if the file is a Deployment
    if ($content -match "kind:\s*Deployment") {
        $deploymentName = ""
        $inReadiness = $false
        
        foreach ($line in $content) {
            # Extract deployment name
            if ($line -match "^\s*name:\s*(.+)" -and -not $deploymentName) {
                $deploymentName = $Matches[1].Trim()
            }
            # Reset tracker for multi-document YAMLs
            if ($line -match "^---") {
                $deploymentName = ""
            }
            # Detect starting of readinessProbe
            if ($line -match "readinessProbe:") {
                $inReadiness = $true
                continue
            }
            # Extract readiness path if inside the probe block
            if ($inReadiness) {
                if ($line -match "^\s{0,6}[a-zA-Z]") {
                    $inReadiness = $false
                } elseif ($line -match "path:\s*(.+)") {
                    [PSCustomObject]@{
                        Folder           = $file.Directory.Name
                        Deployment       = $deploymentName
                        "Readiness Path" = $Matches[1].Trim()
                    }
                    $inReadiness = $false
                }
            }
        }
    }
} | Format-Table -AutoSize

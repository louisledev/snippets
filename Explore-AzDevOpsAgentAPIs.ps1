#####################################################################
# Explore-AzDevOpsAgentAPIs.ps1
#
# Purpose: Exploration script to discover what data the Azure DevOps
#          REST API returns about agents, pools, jobs, and builds.
#
# Usage:
#   1. Set the variables below (org, PAT)
#   2. Run the whole script, or run sections individually in ISE/VSCode
#   3. Inspect the output — each call dumps raw JSON so you can see
#      exactly what fields are available.
#
# Note: This is NOT production code. It's meant for exploration.
#####################################################################

# ── CONFIGURATION ────────────────────────────────────────────────────
$org        = "YOUR_ORG"            # Azure DevOps org name
$project    = "YOUR_PROJECT"        # Project name (needed for some endpoints)
$pat        = "YOUR_PAT"            # Personal Access Token (needs Agent Pools read, Build read)
$apiVersion = "api-version=7.1"

$baseUrl    = "https://dev.azure.com/$org"

# Auth header
$base64Auth = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(":$pat"))
$headers    = @{ Authorization = "Basic $base64Auth" }

# Helper: call API and dump results
function Invoke-DevOpsApi {
    param(
        [string]$Label,
        [string]$Uri
    )
    Write-Host "`n$('=' * 70)" -ForegroundColor Cyan
    Write-Host " $Label" -ForegroundColor Cyan
    Write-Host " GET $Uri" -ForegroundColor DarkGray
    Write-Host "$('=' * 70)" -ForegroundColor Cyan

    try {
        $response = Invoke-RestMethod -Uri $Uri -Headers $headers -Method Get
        # If the response has a .value array, show count + first item in detail
        if ($response.value) {
            Write-Host "  → Returned $($response.value.Count) items" -ForegroundColor Green
            Write-Host "`n  ── First item (full JSON) ──" -ForegroundColor Yellow
            $response.value[0] | ConvertTo-Json -Depth 10 | Write-Host
            Write-Host "`n  ── Summary of all items ──" -ForegroundColor Yellow
            $response.value | Format-Table -AutoSize | Out-String | Write-Host
        }
        else {
            $response | ConvertTo-Json -Depth 10 | Write-Host
        }
        return $response
    }
    catch {
        Write-Host "  ✗ ERROR: $($_.Exception.Message)" -ForegroundColor Red
        return $null
    }
}


#####################################################################
# 1. LIST ALL AGENT POOLS
#    → Discover pool IDs, names, pool type (automation vs deployment)
#####################################################################
$pools = Invoke-DevOpsApi `
    -Label "1. ALL AGENT POOLS" `
    -Uri "$baseUrl/_apis/distributedtask/pools?$apiVersion"


#####################################################################
# 2. PICK A POOL — Get detailed pool info
#    (Change $poolId to explore different pools)
#####################################################################
if ($pools.value) {
    # Default: use the first self-hosted pool that has at least one agent
    $selfHosted = $pools.value | Where-Object { $_.isHosted -eq $false }
    $selectedPool = $selfHosted | Where-Object { $_.size -gt 0 } | Select-Object -First 1
    if (-not $selectedPool) {
        # Fall back to any self-hosted pool (even empty), then any pool with agents
        $selectedPool = $selfHosted | Select-Object -First 1
    }
    if (-not $selectedPool) {
        $selectedPool = $pools.value | Where-Object { $_.size -gt 0 } | Select-Object -First 1
    }
    if (-not $selectedPool) {
        $selectedPool = $pools.value[0]
    }
    $poolId = $selectedPool.id
    Write-Host "`n  → Using pool: '$($selectedPool.name)' (ID: $poolId, agents: $($selectedPool.size))" -ForegroundColor Magenta
} else {
    $poolId = 1  # fallback
}


#####################################################################
# 3. LIST AGENTS IN THE POOL
#    → Agent name, version, OS, status, enabled, capabilities
#    → includeCapabilities=true gives you system & user capabilities
#####################################################################
$agents = Invoke-DevOpsApi `
    -Label "3a. AGENTS IN POOL $poolId (basic)" `
    -Uri "$baseUrl/_apis/distributedtask/pools/$poolId/agents?$apiVersion"

# With full capabilities (system info, installed software, env vars)
$agentsDetailed = Invoke-DevOpsApi `
    -Label "3b. AGENTS IN POOL $poolId (with capabilities)" `
    -Uri "$baseUrl/_apis/distributedtask/pools/$poolId/agents?includeCapabilities=true&includeLastCompletedRequest=true&includeAssignedRequest=true&$apiVersion"

# Show what capabilities look like for the first agent
if ($agentsDetailed.value) {
    $firstAgent = $agentsDetailed.value[0]
    Write-Host "`n  ── System Capabilities (first agent) ──" -ForegroundColor Yellow
    Write-Host "  These tell you about the agent machine:" -ForegroundColor DarkGray
    if ($firstAgent.systemCapabilities) {
        $firstAgent.systemCapabilities.PSObject.Properties | ForEach-Object {
            Write-Host "    $($_.Name) = $($_.Value)"
        }
    }
}


#####################################################################
# 4. SINGLE AGENT DETAIL
#    → Deep dive on one agent
#####################################################################
if ($agents.value) {
    $agentId = $agents.value[0].id
    Invoke-DevOpsApi `
        -Label "4. SINGLE AGENT DETAIL (Agent $agentId)" `
        -Uri "$baseUrl/_apis/distributedtask/pools/$poolId/agents/$($agentId)?includeCapabilities=true&includeLastCompletedRequest=true&includeAssignedRequest=true&$apiVersion"
}


#####################################################################
# 5. JOB REQUESTS (the gold mine for queue/execution metrics)
#    → Shows: queueTime, assignTime, receiveTime, finishTime
#    → Plus: result, agent assignment, pipeline info, demands
#####################################################################
$jobRequests = Invoke-DevOpsApi `
    -Label "5a. JOB REQUESTS for pool $poolId (recent)" `
    -Uri "$baseUrl/_apis/distributedtask/pools/$poolId/jobrequests?$apiVersion"

# If you have many, you can filter by completedRequestCount
Invoke-DevOpsApi `
    -Label "5b. JOB REQUESTS (top 50)" `
    -Uri "$baseUrl/_apis/distributedtask/pools/$poolId/jobrequests?top=50&$apiVersion"

# Show timing breakdown for the first job request
if ($jobRequests.value) {
    $jr = $jobRequests.value[0]
    Write-Host "`n  ── Timing breakdown (first job request) ──" -ForegroundColor Yellow
    Write-Host "    Queue Time  : $($jr.queueTime)"
    Write-Host "    Assign Time : $($jr.assignTime)"
    Write-Host "    Receive Time: $($jr.receiveTime)"
    Write-Host "    Finish Time : $($jr.finishTime)"
    Write-Host "    Result      : $($jr.result)"
    Write-Host "    Agent       : $($jr.reservedAgent.name)"
    Write-Host "    Pipeline    : $($jr.definition.name)"
    if ($jr.queueTime -and $jr.assignTime) {
        $waitTime = ([DateTime]$jr.assignTime - [DateTime]$jr.queueTime).TotalSeconds
        Write-Host "    Wait (secs) : $waitTime" -ForegroundColor Green
    }
    if ($jr.assignTime -and $jr.finishTime) {
        $runTime = ([DateTime]$jr.finishTime - [DateTime]$jr.assignTime).TotalSeconds
        Write-Host "    Run (secs)  : $runTime" -ForegroundColor Green
    }
}


#####################################################################
# 6. POOL USAGE / RESOURCE USAGE (org level)
#    → Parallelism limits, used count
#####################################################################
Invoke-DevOpsApi `
    -Label "6. RESOURCE USAGE (org-level parallelism)" `
    -Uri "$baseUrl/_apis/distributedtask/resourceusage?$apiVersion"


#####################################################################
# 7. BUILDS — recent builds with timing & status
#####################################################################
Invoke-DevOpsApi `
    -Label "7a. RECENT BUILDS (top 10)" `
    -Uri "$baseUrl/$project/_apis/build/builds?`$top=10&$apiVersion"

# Builds with specific status
Invoke-DevOpsApi `
    -Label "7b. CURRENTLY RUNNING BUILDS" `
    -Uri "$baseUrl/$project/_apis/build/builds?statusFilter=inProgress&$apiVersion"

Invoke-DevOpsApi `
    -Label "7c. QUEUED BUILDS" `
    -Uri "$baseUrl/$project/_apis/build/builds?statusFilter=notStarted&$apiVersion"


#####################################################################
# 8. BUILD TIMELINE — per-step breakdown of a build
#    → Shows each task/step with start/finish times, result, log URL
#    → This is how you get fine-grained step-level duration data
#####################################################################
# Get the most recent completed build
$recentBuilds = Invoke-RestMethod `
    -Uri "$baseUrl/$project/_apis/build/builds?`$top=1&statusFilter=completed&$apiVersion" `
    -Headers $headers -Method Get

if ($recentBuilds.value) {
    $buildId = $recentBuilds.value[0].id
    Invoke-DevOpsApi `
        -Label "8. BUILD TIMELINE (step-by-step detail for build $buildId)" `
        -Uri "$baseUrl/$project/_apis/build/builds/$buildId/timeline?$apiVersion"
}


#####################################################################
# 9. BUILD DEFINITIONS (pipelines)
#    → List of all pipeline definitions
#####################################################################
Invoke-DevOpsApi `
    -Label "9. BUILD DEFINITIONS / PIPELINES" `
    -Uri "$baseUrl/$project/_apis/build/definitions?$apiVersion"


#####################################################################
# 10. DEPLOYMENT POOLS & GROUPS (if you use deployment groups)
#####################################################################
Invoke-DevOpsApi `
    -Label "10a. DEPLOYMENT POOLS" `
    -Uri "$baseUrl/_apis/distributedtask/deploymentpools?$apiVersion"

Invoke-DevOpsApi `
    -Label "10b. DEPLOYMENT GROUPS (project-scoped)" `
    -Uri "$baseUrl/$project/_apis/distributedtask/deploymentgroups?$apiVersion"


#####################################################################
# 11. AGENT POOL QUEUE METRICS (preview API)
#    → Some orgs get queue-level metrics from this endpoint
#####################################################################
Invoke-DevOpsApi `
    -Label "11. POOL METRICS (preview — may not be available)" `
    -Uri "$baseUrl/_apis/distributedtask/pools/$poolId/usages?$apiVersion"


#####################################################################
# SUMMARY — What you can get vs. what you can't
#####################################################################
Write-Host "`n$('=' * 70)" -ForegroundColor Magenta
Write-Host " SUMMARY: What the API gives you" -ForegroundColor Magenta
Write-Host "$('=' * 70)" -ForegroundColor Magenta
Write-Host @"

  ✓ AVAILABLE from the API:
    - Agent online/offline/busy status
    - Agent OS, version, capabilities (installed tools, SDKs, env vars)
    - Job queue times, assign times, finish times (calculate wait & duration)
    - Job results (succeeded, failed, canceled)
    - Which agent ran which job
    - Build-level metadata (trigger, branch, requestor, status)
    - Step-by-step build timeline (per-task durations)
    - Parallelism usage (how many slots used vs available)
    - Pipeline definitions and their settings

  ✗ NOT available from the API:
    - Agent CPU / memory / disk usage (host-level metrics)
    - Network throughput on the agent machine
    - Agent process health (crashes, restarts)
    → For these, you need host-level monitoring:
      Prometheus node_exporter, Azure Monitor Agent, Telegraf, etc.
      installed directly on the agent machines.

"@ -ForegroundColor White


Write-Host "Done! Explore the output above to see what fields are available." -ForegroundColor Green
Write-Host "Tip: Pipe any section's output to 'Out-File' or 'ConvertTo-Json | Set-Content' to save for offline review." -ForegroundColor DarkGray

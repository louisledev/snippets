param(
    [Parameter(Mandatory = $true)]
    [string]$Organization,

    [Parameter(Mandatory = $true)]
    [string]$TemplateProject,

    [Parameter(Mandatory = $true)]
    [string]$TemplateRepo,

    [Parameter(Mandatory = $true)]
    [string]$ConsumingProject,

    [Parameter(Mandatory = $true)]
    [string]$PAT
)

$base64Auth = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(":$PAT"))
$headers = @{
    Authorization = "Basic $base64Auth"
    "Content-Type" = "application/json"
}

$baseUrl = "https://dev.azure.com/$Organization"

# --- Retrieve Template Project ID ---
Write-Host "Retrieving Template Project ID for '$TemplateProject'..." -ForegroundColor Cyan
$projectUrl = "$baseUrl/_apis/projects/${TemplateProject}?api-version=7.1"
try {
    $projectResponse = Invoke-RestMethod -Uri $projectUrl -Headers $headers -Method Get
    $templateProjectId = $projectResponse.id
    Write-Host "  Template Project ID: $templateProjectId" -ForegroundColor Green
}
catch {
    Write-Error "Failed to retrieve Template Project ID: $_"
    exit 1
}

# --- Retrieve Template Repo ID ---
Write-Host "Retrieving Template Repo ID for '$TemplateRepo'..." -ForegroundColor Cyan
$repoUrl = "$baseUrl/$TemplateProject/_apis/git/repositories/${TemplateRepo}?api-version=7.1"
try {
    $repoResponse = Invoke-RestMethod -Uri $repoUrl -Headers $headers -Method Get
    $templateRepoId = $repoResponse.id
    Write-Host "  Template Repo ID: $templateRepoId" -ForegroundColor Green
}
catch {
    Write-Error "Failed to retrieve Template Repo ID: $_"
    exit 1
}

# --- Retrieve Pipeline Permissions ---
$resourceId = "$templateProjectId.$templateRepoId"
Write-Host "`nRetrieving Pipeline Permissions for resource '$resourceId' in consuming project '$ConsumingProject'..." -ForegroundColor Cyan
$permissionsUrl = "$baseUrl/$ConsumingProject/_apis/pipelines/pipelinePermissions/repository/${resourceId}?api-version=7.1-preview.1"
try {
    $permissionsResponse = Invoke-RestMethod -Uri $permissionsUrl -Headers $headers -Method Get

    Write-Host "`n--- Pipeline Permissions ---" -ForegroundColor Yellow
    Write-Host "Resource ID:   $($permissionsResponse.resource.id)"
    Write-Host "Resource Type: $($permissionsResponse.resource.type)"
    Write-Host "All Pipelines: $($permissionsResponse.allPipelines.authorized)"

    if ($permissionsResponse.pipelines -and $permissionsResponse.pipelines.Count -gt 0) {
        Write-Host "`nAuthorized Pipelines:" -ForegroundColor Yellow
        foreach ($pipeline in $permissionsResponse.pipelines) {
            Write-Host "  Pipeline ID: $($pipeline.id) | Authorized: $($pipeline.authorized) | By: $($pipeline.authorizedBy.displayName) | On: $($pipeline.authorizedOn)"
        }
    }
    else {
        Write-Host "`nNo individually authorized pipelines found." -ForegroundColor DarkYellow
    }
}
catch {
    Write-Error "Failed to retrieve Pipeline Permissions: $_"
    exit 1
}

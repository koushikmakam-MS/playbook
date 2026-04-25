# ─────────────────────────────────────────────
# GitProviders.psm1 — Pluggable Git Provider Layer
# Supports: ADO, GitHub, GitLab, git-only (fallback)
# ─────────────────────────────────────────────

Set-StrictMode -Version Latest

# ─────────────────────────────────────────────
# Region: Provider Detection
# ─────────────────────────────────────────────

function Get-GitProvider {
    <#
    .SYNOPSIS
        Auto-detects git provider from remote URL or accepts explicit override.
    .RETURNS
        Provider name: 'ado', 'github', 'gitlab', 'git'
    #>
    param(
        [string]$RemoteUrl,
        [string]$Override,
        [string]$WorkingDirectory
    )

    if ($Override) {
        $valid = @('ado', 'github', 'gitlab', 'git')
        if ($Override -notin $valid) {
            throw "Invalid git provider '$Override'. Valid: $($valid -join ', ')"
        }
        return $Override
    }

    # Auto-detect from URL
    if (-not $RemoteUrl -and $WorkingDirectory) {
        Push-Location $WorkingDirectory
        $RemoteUrl = & git --no-pager remote get-url origin 2>&1
        Pop-Location
        if ($LASTEXITCODE -ne 0) { return 'git' }
    }

    if (-not $RemoteUrl) { return 'git' }

    switch -Regex ($RemoteUrl) {
        'dev\.azure\.com|visualstudio\.com|azure\.com' { return 'ado' }
        'github\.com'                                   { return 'github' }
        'gitlab\.com|gitlab\.'                          { return 'gitlab' }
        default                                         { return 'git' }
    }
}

# ─────────────────────────────────────────────
# Region: Auth Verification
# ─────────────────────────────────────────────

function Test-GitAuth {
    <#
    .SYNOPSIS
        Verifies the user has valid auth for the detected provider.
    .RETURNS
        Hashtable: @{ Authenticated = $bool; Tool = 'string'; User = 'string' }
    #>
    param(
        [Parameter(Mandatory)]
        [string]$Provider,

        [string]$WorkingDirectory
    )

    switch ($Provider) {
        'ado' {
            $az = Get-Command az -ErrorAction SilentlyContinue
            if (-not $az) {
                return @{ Authenticated = $false; Tool = 'az'; Error = 'Azure CLI not found' }
            }
            $account = & az account show --query "user.name" -o tsv 2>&1
            if ($LASTEXITCODE -eq 0 -and $account) {
                return @{ Authenticated = $true; Tool = 'az'; User = $account }
            }
            return @{ Authenticated = $false; Tool = 'az'; Error = 'Not logged in (run: az login)' }
        }
        'github' {
            $gh = Get-Command gh -ErrorAction SilentlyContinue
            if (-not $gh) {
                return @{ Authenticated = $false; Tool = 'gh'; Error = 'GitHub CLI not found' }
            }
            $status = & gh auth status 2>&1 | Out-String
            if ($status -match 'Logged in') {
                $user = & gh api user --jq '.login' 2>&1
                return @{ Authenticated = $true; Tool = 'gh'; User = $user }
            }
            return @{ Authenticated = $false; Tool = 'gh'; Error = 'Not authenticated (run: gh auth login)' }
        }
        'gitlab' {
            $glab = Get-Command glab -ErrorAction SilentlyContinue
            if (-not $glab) {
                # Fall back to checking GITLAB_TOKEN env var
                if ($env:GITLAB_TOKEN) {
                    return @{ Authenticated = $true; Tool = 'env:GITLAB_TOKEN'; User = 'token-auth' }
                }
                return @{ Authenticated = $false; Tool = 'glab'; Error = 'GitLab CLI not found and GITLAB_TOKEN not set' }
            }
            $status = & glab auth status 2>&1 | Out-String
            if ($LASTEXITCODE -eq 0) {
                return @{ Authenticated = $true; Tool = 'glab'; User = 'glab-auth' }
            }
            return @{ Authenticated = $false; Tool = 'glab'; Error = 'Not authenticated' }
        }
        'git' {
            return @{ Authenticated = $true; Tool = 'git'; User = 'local-only' }
        }
    }
}

# ─────────────────────────────────────────────
# Region: Pull Request Creation
# ─────────────────────────────────────────────

function New-GitPullRequest {
    <#
    .SYNOPSIS
        Creates a pull request using the provider's native CLI.
    .RETURNS
        Hashtable: @{ Created = $bool; Url = 'string'; Error = 'string' }
    #>
    param(
        [Parameter(Mandatory)]
        [string]$Provider,

        [Parameter(Mandatory)]
        [string]$WorkingDirectory,

        [Parameter(Mandatory)]
        [string]$SourceBranch,

        [Parameter(Mandatory)]
        [string]$TargetBranch,

        [string]$Title = "docs: Monkey Army documentation updates",

        [string]$Body = "Auto-generated documentation by Monkey Army 🐒"
    )

    Push-Location $WorkingDirectory

    try {
        # Push first
        Write-Host "  Pushing '$SourceBranch' to origin..." -ForegroundColor Cyan
        & git push origin $SourceBranch 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) {
            return @{ Created = $false; Url = ''; Error = "git push failed" }
        }

        switch ($Provider) {
            'ado' {
                $remoteUrl = & git --no-pager remote get-url origin 2>&1
                # Extract org/project/repo from ADO URL patterns
                $prResult = & az repos pr create `
                    --source-branch $SourceBranch `
                    --target-branch $TargetBranch `
                    --title $Title `
                    --description $Body `
                    --auto-complete false `
                    --output json 2>&1 | Out-String

                if ($LASTEXITCODE -eq 0) {
                    try {
                        $pr = $prResult | ConvertFrom-Json
                        $prUrl = $pr.url -replace '_apis/git/repositories/.*/pullRequests/', '_git/pullrequest/'
                        return @{ Created = $true; Url = $prUrl; Id = $pr.pullRequestId }
                    }
                    catch {
                        return @{ Created = $true; Url = '(check ADO portal)'; Id = '' }
                    }
                }
                return @{ Created = $false; Url = ''; Error = $prResult }
            }
            'github' {
                $prResult = & gh pr create `
                    --head $SourceBranch `
                    --base $TargetBranch `
                    --title $Title `
                    --body $Body 2>&1 | Out-String

                if ($LASTEXITCODE -eq 0) {
                    $url = ($prResult -split "`n" | Where-Object { $_ -match 'https://' } | Select-Object -First 1).Trim()
                    return @{ Created = $true; Url = $url }
                }
                return @{ Created = $false; Url = ''; Error = $prResult }
            }
            'gitlab' {
                if (Get-Command glab -ErrorAction SilentlyContinue) {
                    $prResult = & glab mr create `
                        --source-branch $SourceBranch `
                        --target-branch $TargetBranch `
                        --title $Title `
                        --description $Body `
                        --no-editor 2>&1 | Out-String

                    if ($LASTEXITCODE -eq 0) {
                        $url = ($prResult -split "`n" | Where-Object { $_ -match 'https://' } | Select-Object -First 1).Trim()
                        return @{ Created = $true; Url = $url }
                    }
                    return @{ Created = $false; Url = ''; Error = $prResult }
                }
                return @{ Created = $false; Url = ''; Error = 'glab CLI not available' }
            }
            'git' {
                Write-Host "  [git-only mode] Branch pushed. Create PR manually." -ForegroundColor Yellow
                return @{ Created = $false; Url = ''; Error = 'No PR CLI available (git-only mode)' }
            }
        }
    }
    finally {
        Pop-Location
    }
}

# ─────────────────────────────────────────────
# Region: Repository Metadata
# ─────────────────────────────────────────────

function Get-RepoMetadata {
    <#
    .SYNOPSIS
        Gathers repo stats used for model selection and quality gating.
    .RETURNS
        Hashtable with file counts, languages, size info.
    #>
    param(
        [Parameter(Mandatory)]
        [string]$WorkingDirectory
    )

    Push-Location $WorkingDirectory

    try {
        # File count
        $allFiles = & git ls-files 2>&1
        $fileCount = @($allFiles).Count

        # Language breakdown (by extension)
        $langMap = @{}
        foreach ($f in $allFiles) {
            $ext = [System.IO.Path]::GetExtension($f).ToLower()
            if ($ext) {
                if (-not $langMap.ContainsKey($ext)) { $langMap[$ext] = 0 }
                $langMap[$ext]++
            }
        }

        # Top languages
        $topLangs = $langMap.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First 5

        # Primary language detection
        $langNames = @{
            '.cs' = 'csharp'; '.py' = 'python'; '.js' = 'javascript'; '.ts' = 'typescript'
            '.java' = 'java'; '.go' = 'go'; '.rb' = 'ruby'; '.php' = 'php'
            '.kt' = 'kotlin'; '.rs' = 'rust'; '.cpp' = 'cpp'; '.c' = 'c'
            '.swift' = 'swift'; '.scala' = 'scala'
        }
        $primaryExt = if ($topLangs) { $topLangs[0].Key } else { '' }
        $primaryLang = if ($langNames.ContainsKey($primaryExt)) { $langNames[$primaryExt] } else { 'unknown' }

        # Remote URL
        $remoteUrl = & git --no-pager remote get-url origin 2>&1
        if ($LASTEXITCODE -ne 0) { $remoteUrl = '' }

        # Repo size (rough estimate from git)
        $sizeKB = 0
        try {
            $sizeOutput = & git count-objects -v 2>&1 | Out-String
            if ($sizeOutput -match 'size-pack:\s*(\d+)') { $sizeKB = [int]$Matches[1] }
        }
        catch { }

        return @{
            FileCount    = $fileCount
            PrimaryLang  = $primaryLang
            TopLanguages = @($topLangs | ForEach-Object { @{ Extension = $_.Key; Count = $_.Value } })
            RemoteUrl    = [string]$remoteUrl
            SizeKB       = $sizeKB
            SizeTier     = if ($fileCount -lt 300) { 'small' } elseif ($fileCount -lt 800) { 'medium' } else { 'large' }
        }
    }
    finally {
        Pop-Location
    }
}

# ─────────────────────────────────────────────
# Region: Model Selection by Repo Size
# ─────────────────────────────────────────────

function Select-ModelForRepo {
    <#
    .SYNOPSIS
        2-stage model selection: probe available models, then pick best for repo size + mode.
    #>
    param(
        [string]$SizeTier,     # small|medium|large
        [string]$Mode = 'prompt',  # prompt|agent
        [string]$UserOverride
    )

    if ($UserOverride) { return $UserOverride }

    # Tier-based preference (from Run-Player.ps1 patterns)
    $preference = switch ($SizeTier) {
        'small'  {
            if ($Mode -eq 'agent') { @('claude-sonnet-4.5', 'claude-sonnet-4', 'gpt-4.1') }
            else { @('claude-sonnet-4', 'gpt-4.1') }
        }
        'medium' {
            if ($Mode -eq 'agent') { @('claude-opus-4.7', 'claude-sonnet-4.5', 'claude-sonnet-4') }
            else { @('claude-sonnet-4', 'claude-opus-4.7', 'gpt-4.1') }
        }
        'large'  {
            if ($Mode -eq 'agent') { @('claude-opus-4.6-1m', 'claude-opus-4.7', 'claude-sonnet-4.5') }
            else { @('claude-opus-4.7', 'claude-sonnet-4', 'gpt-4.1') }
        }
        default { @('claude-sonnet-4', 'gpt-4.1') }
    }

    return $preference
}

# Export
Export-ModuleMember -Function @(
    'Get-GitProvider'
    'Test-GitAuth'
    'New-GitPullRequest'
    'Get-RepoMetadata'
    'Select-ModelForRepo'
)

# ─────────────────────────────────────────────
# MonkeyCommon.psm1 — Shared infrastructure for Monkey Army 🐒
# Provides: UI helpers, copilot invocation, git/setup, model selection,
#           pre-validation, doc-reference parsing, commit/stage, preflight
# ─────────────────────────────────────────────

Set-StrictMode -Version Latest

# ─────────────────────────────────────────────
# Region: Constants
# ─────────────────────────────────────────────

# Retry-related error patterns
$script:RETRYABLE_PATTERNS = @(
    'capacity'
    'rate.?limit'
    '429'
    '503'
    'overloaded'
    'try again'
    'too many requests'
    'server error'
    'timeout'
    'ETIMEDOUT'
    'ECONNRESET'
)

# Model probe order (best coding models first)
$script:MODEL_PRIORITY = @(
    "claude-sonnet-4"
    "gpt-4.1"
)

# Doc-reference detection patterns (generic — works on any repo)
$script:DocRefPatterns = @(
    @{ Name = 'docs_path';    Pattern = 'docs[/\\]' }
    @{ Name = 'md_file';      Pattern = '[\w\-]+\.md' }
    @{ Name = 'workflow';     Pattern = 'workflow[s]?\s*(doc|file|ref)' }
    @{ Name = 'readme';       Pattern = 'README\.md|readme\.md' }
    @{ Name = 'wiki_ref';     Pattern = 'wiki[/\\]|\.wiki\b' }
    @{ Name = 'doc_dir';      Pattern = 'doc[/\\]|documentation[/\\]' }
    @{ Name = 'api_doc';      Pattern = 'swagger|openapi|api[_-]?doc' }
    @{ Name = 'changelog';    Pattern = 'CHANGELOG|CHANGES|HISTORY' }
    @{ Name = 'guide_ref';    Pattern = 'guide[/\\]|tutorial|howto|getting.started' }
    @{ Name = 'arch_ref';     Pattern = 'architect|design[_-]?doc|ADR|decision' }
)

# ─────────────────────────────────────────────
# Region: UI Helpers
# ─────────────────────────────────────────────

function Write-MonkeyBanner {
    param(
        [string]$Name,
        [string]$Emoji,
        [string]$Version,
        [string]$Tagline
    )
    $banner = @"

  ╔══════════════════════════════════════════╗
  ║     $Emoji $Name v$Version $Emoji        ║
  ║   $Tagline   ║
  ╚══════════════════════════════════════════╝

"@
    Write-Host $banner -ForegroundColor Cyan
}

function Write-Phase {
    param([string]$Phase, [string]$Message)
    Write-Host "`n[$Phase] " -ForegroundColor Yellow -NoNewline
    Write-Host $Message -ForegroundColor White
    Write-Host ("─" * 60) -ForegroundColor DarkGray
}

function Write-Step {
    param([string]$Message, [string]$Status = "INFO")
    $color = switch ($Status) {
        "OK"    { "Green" }
        "WARN"  { "Yellow" }
        "ERROR" { "Red" }
        "SKIP"  { "DarkGray" }
        default { "Cyan" }
    }
    Write-Host "  [$Status] " -ForegroundColor $color -NoNewline
    Write-Host $Message
}

function Write-MonkeySummary {
    param(
        [hashtable]$Stats,
        [string]$Emoji = "🐵"
    )
    Write-Host "`n" -NoNewline
    Write-Host "  ╔══════════════════════════════════════════╗" -ForegroundColor Cyan
    Write-Host "  ║          $Emoji RUN SUMMARY                  ║" -ForegroundColor Cyan
    Write-Host "  ╚══════════════════════════════════════════╝" -ForegroundColor Cyan
    foreach ($key in $Stats.Keys | Sort-Object) {
        $val = $Stats[$key]
        $color = "White"
        if ($key -match 'Failed|Error' -and $val -gt 0) { $color = "Red" }
        elseif ($key -match 'Answered|OK|Grounded' -and $val -gt 0) { $color = "Green" }
        elseif ($key -match 'Retry|Warn' -and $val -gt 0) { $color = "Yellow" }
        $paddedKey = $key.PadRight(25)
        Write-Host "  $paddedKey : $val" -ForegroundColor $color
    }
    Write-Host ""
}

# ─────────────────────────────────────────────
# Region: Copilot Invocation with Retry
# ─────────────────────────────────────────────

function Invoke-CopilotWithRetry {
    <#
    .SYNOPSIS
        Invokes copilot -p with retry logic, timeout handling, and error classification.
        Uses PowerShell jobs for timeout support (avoids Process wrapper issues with .ps1 shims).
    #>
    param(
        [Parameter(Mandatory)]
        [string]$Prompt,

        [string]$ModelName,

        [string]$SharePath,

        [string]$WorkingDirectory,

        [int]$Retries = 3,

        [int]$BaseDelay = 30,

        [int]$Timeout = 300,

        [switch]$ShowVerbose
    )

    $attempt = 0
    $lastError = $null

    while ($attempt -le $Retries) {
        if ($attempt -gt 0) {
            $delay = $BaseDelay * [math]::Pow(2, $attempt - 1)
            Write-Step "Retry $attempt/$Retries in ${delay}s..." "WARN"
            Start-Sleep -Seconds $delay
        }

        try {
            $copilotArgs = @("-p", $Prompt, "--yolo", "--no-ask-user", "-s")
            if ($ModelName) { $copilotArgs += @("--model", $ModelName) }
            if ($SharePath) { $copilotArgs += @("--share=$SharePath") }

            $job = Start-Job -ScriptBlock {
                param($wd, $args_)
                Set-Location $wd
                $output = & copilot @args_ 2>&1
                @{
                    ExitCode = $LASTEXITCODE
                    Output   = ($output | Out-String).Trim()
                }
            } -ArgumentList $WorkingDirectory, $copilotArgs

            $completed = $job | Wait-Job -Timeout $Timeout

            if (-not $completed) {
                $job | Stop-Job -ErrorAction SilentlyContinue
                $job | Remove-Job -Force -ErrorAction SilentlyContinue
                $lastError = "TIMEOUT after ${Timeout}s"
                Write-Step "Call timed out after ${Timeout}s" "WARN"
                $attempt++
                continue
            }

            $jobResult = $job | Receive-Job
            $job | Remove-Job -Force -ErrorAction SilentlyContinue

            $exitCode = $jobResult.ExitCode
            $stdout = $jobResult.Output

            if ($ShowVerbose -and $stdout) {
                Write-Host $stdout -ForegroundColor DarkGray
            }

            if ($exitCode -eq 0 -or $null -eq $exitCode) {
                return @{
                    Success = $true
                    Output  = $stdout
                    Stderr  = ""
                    Retries = $attempt
                }
            }

            # Check if error is retryable
            $isRetryable = $false
            foreach ($pattern in $script:RETRYABLE_PATTERNS) {
                if ($stdout -match $pattern) {
                    $isRetryable = $true
                    break
                }
            }

            if ($isRetryable) {
                $lastError = $stdout
                Write-Step "Retryable error: $($stdout.Substring(0, [Math]::Min(100, $stdout.Length)))" "WARN"
                $attempt++
                continue
            }

            return @{
                Success = $false
                Output  = $stdout
                Stderr  = ""
                Error   = "Exit code $exitCode`: $stdout"
                Retries = $attempt
            }
        }
        catch {
            $lastError = $_.Exception.Message
            Write-Step "Exception: $lastError" "ERROR"
            $attempt++
            continue
        }
    }

    return @{
        Success = $false
        Output  = ""
        Stderr  = ""
        Error   = "All $Retries retries exhausted. Last error: $lastError"
        Retries = $attempt
    }
}

# ─────────────────────────────────────────────
# Region: Batch Execution
# ─────────────────────────────────────────────

function Get-QuestionId {
    <#
    .SYNOPSIS
        Generates a stable hash-based ID for a question (EntryPoint + Question text).
        Used for checkpoint tracking — survives reordering and filtering.
    #>
    param(
        [string]$EntryPoint,
        [string]$Question
    )
    $raw = "$EntryPoint|$Question"
    $sha = [System.Security.Cryptography.SHA256]::Create()
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($raw)
    $hash = $sha.ComputeHash($bytes)
    return [BitConverter]::ToString($hash[0..7]).Replace('-', '').ToLower()
}

function Get-BatchCheckpoint {
    <#
    .SYNOPSIS
        Reads the batch checkpoint file. Returns a set of completed question IDs.
    #>
    param([string]$OutputPath)
    $cpPath = Join-Path $OutputPath "batch-checkpoint.json"
    if (Test-Path $cpPath) {
        try {
            $data = Get-Content $cpPath -Raw | ConvertFrom-Json
            $set = [System.Collections.Generic.HashSet[string]]::new()
            foreach ($id in $data.CompletedIds) { [void]$set.Add($id) }
            return $set
        }
        catch {
            Write-Step "Corrupt checkpoint — starting fresh" "WARN"
            return [System.Collections.Generic.HashSet[string]]::new()
        }
    }
    return [System.Collections.Generic.HashSet[string]]::new()
}

function Save-BatchCheckpoint {
    <#
    .SYNOPSIS
        Atomically writes the batch checkpoint file (temp + rename).
    #>
    param(
        [string]$OutputPath,
        [System.Collections.Generic.HashSet[string]]$CompletedIds
    )
    $cpPath = Join-Path $OutputPath "batch-checkpoint.json"
    $tmpPath = "$cpPath.tmp"
    $data = @{
        CompletedIds = @($CompletedIds)
        LastUpdated  = (Get-Date).ToString('o')
        Count        = $CompletedIds.Count
    }
    $data | ConvertTo-Json -Depth 3 | Set-Content $tmpPath -Encoding UTF8
    Move-Item $tmpPath $cpPath -Force
}

function Invoke-CopilotBatch {
    <#
    .SYNOPSIS
        Sends a batch of questions to a single copilot CLI call.
        Uses GUID-based delimiters for reliable parsing.
        Returns per-question results array.
    #>
    param(
        [Parameter(Mandatory)]
        [array]$Questions,

        [string]$WorkingDirectory,
        [string]$OutputPath,
        [string]$ModelName,
        [string]$SharePath,
        [int]$Retries = 2,
        [int]$BaseDelay = 30,
        [int]$TimeoutPerQuestion = 180,
        [switch]$ShowVerbose
    )

    $batchId = [guid]::NewGuid().ToString('N').Substring(0, 8)
    $totalTimeout = $Questions.Count * $TimeoutPerQuestion

    # Build the mega-prompt with questions embedded directly
    $questionBlock = ""
    foreach ($q in $Questions) {
        $idx = $q.BatchIndex
        $ep = if ($q.EntryPoint) { " (file: $($q.EntryPoint))" } else { "" }
        $docHealSuffix = " If relevant documentation for this topic is missing or incomplete in the repo, create or update it following existing doc patterns."
        $questionBlock += @"

--- QUESTION [$batchId-$idx] ---
$($q.Question)${ep}${docHealSuffix}

"@
    }

    $megaPrompt = @"
You have $($Questions.Count) questions to answer about this codebase. Answer each one in order.

IMPORTANT: Before each answer, output exactly this marker on its own line:
>>> ANSWER [$batchId-<N>] <<<
where <N> is the question number shown below. After your last answer, output:
>>> BATCH DONE [$batchId] <<<

Here are the questions:
$questionBlock
Remember: Start each answer with >>> ANSWER [$batchId-<N>] <<< and end with >>> BATCH DONE [$batchId] <<<
"@

    Write-Step "Batch ${batchId}: $($Questions.Count) questions, timeout ${totalTimeout}s" "INFO"

    $result = Invoke-CopilotWithRetry `
        -Prompt $megaPrompt `
        -ModelName $ModelName `
        -SharePath $SharePath `
        -WorkingDirectory $WorkingDirectory `
        -Retries $Retries `
        -BaseDelay $BaseDelay `
        -Timeout $totalTimeout `
        -ShowVerbose:$ShowVerbose

    # Parse results — even partial output is valuable
    $questionResults = @()
    $rawOutput = if ($result.Success) { $result.Output } else { $result.Output }
    $batchComplete = $rawOutput -match ">>> BATCH DONE \[$batchId\] <<<"

    foreach ($q in $Questions) {
        $idx = $q.BatchIndex
        $startMarker = ">>> ANSWER \[$batchId-$idx\] <<<"
        $nextIdx = $idx + 1
        $endMarker = ">>> ANSWER \[$batchId-$nextIdx\] <<<"

        # Try to extract this question's answer
        $answer = $null
        if ($rawOutput -match "(?s)$startMarker(.+?)(?:$endMarker|>>> BATCH DONE)") {
            $answer = $Matches[1].Trim()
        }
        elseif ($rawOutput -match "(?s)$startMarker(.+)$") {
            # Last question or truncated — grab everything after marker
            $answer = $Matches[1] -replace ">>> BATCH DONE.*$", "" | ForEach-Object { $_.Trim() }
        }

        $questionResults += @{
            QuestionId  = $q.QuestionId
            BatchIndex  = $idx
            EntryPoint  = $q.EntryPoint
            Question    = $q.Question
            Category    = $q.Category
            Success     = ($null -ne $answer -and $answer.Length -gt 20)
            Output      = if ($answer) { $answer } else { "" }
            Error       = if (-not $answer) { "No answer parsed from batch output" } else { $null }
        }
    }

    $parsed = @($questionResults | Where-Object { $_.Success }).Count
    $batchStatus = if ($batchComplete -and $parsed -eq $Questions.Count) { "COMPLETE" }
                   elseif ($parsed -gt 0) { "PARTIAL" }
                   else { "FAILED" }

    Write-Step "Batch ${batchId}: ${batchStatus} — ${parsed}/$($Questions.Count) parsed" $(
        switch ($batchStatus) { "COMPLETE" { "OK" } "PARTIAL" { "WARN" } "FAILED" { "ERROR" } }
    )

    return @{
        BatchId         = $batchId
        Status          = $batchStatus
        QuestionResults = $questionResults
        RawOutput       = $rawOutput
        Retries         = $result.Retries
        BatchComplete   = $batchComplete
    }
}

# ─────────────────────────────────────────────
# Region: Incremental Mode
# ─────────────────────────────────────────────

function Get-IncrementalState {
    <#
    .SYNOPSIS
        Reads the last-run state for incremental mode.
        Returns $null if no prior run exists.
    #>
    param([string]$WorkingDirectory)
    $statePath = Join-Path $WorkingDirectory ".playbook-state" "last-run.json"
    if (Test-Path $statePath) {
        try {
            return Get-Content $statePath -Raw | ConvertFrom-Json
        }
        catch {
            Write-Step "Corrupt incremental state — treating as full run" "WARN"
            return $null
        }
    }
    return $null
}

function Save-IncrementalState {
    <#
    .SYNOPSIS
        Saves the current run state for future incremental runs.
        Writes atomically (temp + rename).
    #>
    param(
        [string]$WorkingDirectory,
        [string]$MonkeyName,
        [string]$CommitHash,
        [int]$EntryPointCount,
        [int]$QuestionsAsked
    )
    $stateDir = Join-Path $WorkingDirectory ".playbook-state"
    New-Item -ItemType Directory -Path $stateDir -Force | Out-Null

    $state = @{
        LastRunAt      = (Get-Date).ToString('o')
        MonkeyName     = $MonkeyName
        CommitHash     = $CommitHash
        EntryPoints    = $EntryPointCount
        QuestionsAsked = $QuestionsAsked
    }

    $statePath = Join-Path $stateDir "last-run.json"
    $tmpPath = "$statePath.tmp"
    $state | ConvertTo-Json -Depth 3 | Set-Content $tmpPath -Encoding UTF8
    Move-Item $tmpPath $statePath -Force
}

function Get-ChangedFiles {
    <#
    .SYNOPSIS
        Returns file paths changed since a given commit or date.
        Used by incremental mode to filter entry points to only changed files.
    .PARAMETER WorkingDirectory
        The repo root.
    .PARAMETER Since
        A git ref (commit hash, branch, tag) or date string (e.g., "2024-01-01", "3 days ago").
    .PARAMETER FileGlobs
        Optional glob patterns to filter results (e.g., "*.cs", "*.py").
    #>
    param(
        [Parameter(Mandatory)]
        [string]$WorkingDirectory,

        [Parameter(Mandatory)]
        [string]$Since,

        [string[]]$FileGlobs
    )

    Push-Location $WorkingDirectory
    try {
        # Try as commit ref first
        $files = & git --no-pager diff --name-only "$Since" HEAD 2>&1
        if ($LASTEXITCODE -ne 0) {
            # Try as date
            $files = & git --no-pager log --since="$Since" --name-only --pretty=format:"" HEAD 2>&1
            if ($LASTEXITCODE -ne 0) {
                Write-Step "Could not resolve --since='$Since' as ref or date" "ERROR"
                return @()
            }
        }

        # Deduplicate and filter
        $changedFiles = @($files | Where-Object { $_ -and $_.Trim() } | Sort-Object -Unique)

        if ($FileGlobs -and $FileGlobs.Count -gt 0) {
            $filtered = @()
            foreach ($f in $changedFiles) {
                foreach ($glob in $FileGlobs) {
                    if ($f -like $glob) {
                        $filtered += $f
                        break
                    }
                }
            }
            $changedFiles = $filtered
        }

        Write-Step "Incremental: $($changedFiles.Count) files changed since '$Since'" "INFO"
        return $changedFiles
    }
    finally {
        Pop-Location
    }
}

function Select-IncrementalEntryPoints {
    <#
    .SYNOPSIS
        Filters a list of entry points to only those whose files have changed.
        Entry points have a .Path or .RelPath property.
    .PARAMETER EntryPoints
        Array of entry point hashtables with Path/RelPath keys.
    .PARAMETER ChangedFiles
        Array of relative file paths from Get-ChangedFiles.
    .PARAMETER WorkingDirectory
        Repo root for path normalization.
    #>
    param(
        [array]$EntryPoints,
        [array]$ChangedFiles,
        [string]$WorkingDirectory
    )

    if (-not $ChangedFiles -or $ChangedFiles.Count -eq 0) {
        Write-Step "No changed files — skipping all entry points" "WARN"
        return @()
    }

    # Normalize changed files to forward-slash for comparison
    $changedSet = [System.Collections.Generic.HashSet[string]]::new(
        [System.StringComparer]::OrdinalIgnoreCase
    )
    foreach ($f in $ChangedFiles) {
        [void]$changedSet.Add($f.Replace('\', '/').TrimStart('/'))
    }

    $filtered = @()
    foreach ($ep in $EntryPoints) {
        $relPath = if ($ep.RelPath) { $ep.RelPath } else {
            $ep.Path.Substring($WorkingDirectory.Length + 1)
        }
        $normalized = $relPath.Replace('\', '/').TrimStart('/')

        if ($changedSet.Contains($normalized)) {
            $filtered += $ep
        }
    }

    $skipped = $EntryPoints.Count - $filtered.Count
    Write-Step "Incremental filter: $($filtered.Count) changed, $skipped unchanged (skipped)" "OK"
    return $filtered
}

# ─────────────────────────────────────────────
# Region: Doc-Reference Parsing
# ─────────────────────────────────────────────

function Get-DocReferences {
    <#
    .SYNOPSIS
        Parses a copilot response for documentation references.
        Returns a hashtable with reference counts and matched doc paths.
    #>
    param([string]$ResponseText)

    $refs = @{
        TotalRefs     = 0
        DocPaths      = @()
        PatternHits   = @{}
        IsDocGrounded = $false
    }

    if (-not $ResponseText) { return $refs }

    foreach ($p in $script:DocRefPatterns) {
        $matches_ = [regex]::Matches($ResponseText, $p.Pattern, 'IgnoreCase')
        if ($matches_.Count -gt 0) {
            $refs.PatternHits[$p.Name] = $matches_.Count
            $refs.TotalRefs += $matches_.Count
        }
    }

    $mdPaths = [regex]::Matches($ResponseText, '[\w\-/\\]+\.md', 'IgnoreCase')
    $refs.DocPaths = @($mdPaths | ForEach-Object { $_.Value } | Sort-Object -Unique)
    $refs.IsDocGrounded = ($refs.TotalRefs -gt 0)
    return $refs
}

# ─────────────────────────────────────────────
# Region: Setup (Clone / Branch)
# ─────────────────────────────────────────────

function Invoke-MonkeySetup {
    <#
    .SYNOPSIS
        Shared setup: resolve branch, clone/locate repo, create working branch, output dir.
    #>
    param(
        [string]$RepoUrl,
        [string]$ClonePath,
        [string]$RepoPath,
        [string]$BaseBranch,
        [switch]$UseBaseBranch,
        [string]$BranchName,
        [string]$BranchPrefix = "monkey",
        [string]$OutputDirName = ".monkey-output",
        [switch]$NonInteractive
    )

    Write-Phase "PHASE 1" "Setup — Clone / Branch"

    $workDir = $null

    # ── Resolve base branch ──
    if (-not $BaseBranch) {
        if (-not $NonInteractive -and $RepoPath -and (Test-Path $RepoPath)) {
            Push-Location $RepoPath
            Write-Host ""
            Write-Host "  Available remote branches:" -ForegroundColor Cyan
            $branches = & git --no-pager branch -r 2>&1 | ForEach-Object { $_.Trim() -replace '^origin/', '' } | Where-Object { $_ -and $_ -notmatch 'HEAD' } | Select-Object -First 20
            Pop-Location
            for ($i = 0; $i -lt $branches.Count; $i++) {
                Write-Host "    [$i] $($branches[$i])" -ForegroundColor DarkGray
            }
            Write-Host ""
            $userInput = Read-Host "  Enter base branch name or number (default: develop)"
            if ([string]::IsNullOrWhiteSpace($userInput)) {
                $BaseBranch = "develop"
            }
            elseif ($branches -and $userInput -match '^\d+$' -and [int]$userInput -lt $branches.Count) {
                $BaseBranch = $branches[[int]$userInput]
            }
            else {
                $BaseBranch = $userInput
            }
        }
        else {
            $BaseBranch = "develop"
        }
        Write-Step "Base branch: $BaseBranch" "OK"
    }

    # ── Clone or locate repo ──
    if ($RepoPath) {
        if (-not (Test-Path $RepoPath)) {
            throw "RepoPath '$RepoPath' does not exist."
        }
        $workDir = Resolve-Path $RepoPath
        Write-Step "Using existing repo: $workDir" "OK"
    }
    elseif ($RepoUrl) {
        if ($ClonePath -eq ".\monkey-workspace" -and -not $NonInteractive) {
            Write-Host ""
            $userClonePath = Read-Host "  Where should we clone the repo? (default: $ClonePath)"
            if (-not [string]::IsNullOrWhiteSpace($userClonePath)) {
                $ClonePath = $userClonePath
            }
        }
        if (Test-Path $ClonePath) {
            Write-Step "Clone path exists, reusing..." "INFO"
            $workDir = Resolve-Path $ClonePath
        }
        else {
            New-Item -ItemType Directory -Path $ClonePath -Force | Out-Null
            Write-Step "Shallow cloning $RepoUrl → $ClonePath (depth=1, branch=$BaseBranch)" "INFO"
            & git clone --depth 1 --branch $BaseBranch $RepoUrl $ClonePath 2>&1 | Out-Null
            if ($LASTEXITCODE -ne 0) { throw "git clone failed" }
            $workDir = Resolve-Path $ClonePath
            Write-Step "Shallow clone complete (no history)" "OK"
        }
    }
    else {
        throw "Either -RepoUrl or -RepoPath must be provided."
    }

    Push-Location $workDir

    # ── Checkout base branch ──
    Write-Step "Checking out '$BaseBranch' and pulling latest..." "INFO"
    & git checkout $BaseBranch 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) {
        & git checkout -b $BaseBranch "origin/$BaseBranch" 2>&1 | Out-Null
    }
    $isShallow = Test-Path (Join-Path $workDir ".git/shallow")
    if (-not $isShallow) {
        & git pull origin $BaseBranch 2>&1 | Out-Null
    }
    Write-Step "On latest '$BaseBranch'" "OK"

    # ── Branch strategy ──
    $actualBranch = $null
    if (-not $UseBaseBranch -and -not $BranchName) {
        if ($NonInteractive) {
            # Non-interactive default: create new branch
            Write-Step "Non-interactive: creating new branch" "INFO"
        }
        else {
            Write-Host ""
            $branchChoice = Read-Host "  Branch strategy: [1] Create new branch ($BranchPrefix/<timestamp>) or [2] Work on '$BaseBranch' directly? (default: 1)"
            if ($branchChoice -eq '2') {
                $UseBaseBranch = $true
            }
        }
    }

    if ($UseBaseBranch) {
        $actualBranch = $BaseBranch
        Write-Step "Working directly on '$BaseBranch'" "OK"
    }
    else {
        if (-not $BranchName) {
            $timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
            $BranchName = "$BranchPrefix/$timestamp"
        }
        & git checkout -b $BranchName 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "Failed to create branch '$BranchName'" }
        $actualBranch = $BranchName
        Write-Step "Created branch: $BranchName" "OK"
    }

    # ── Output directory ──
    $outputPath = Join-Path $workDir $OutputDirName
    New-Item -ItemType Directory -Path $outputPath -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $outputPath "session-logs") -Force | Out-Null
    Write-Step "Output dir: $outputPath" "OK"

    Pop-Location

    return @{
        WorkDir    = [string]$workDir
        Branch     = $actualBranch
        BaseBranch = $BaseBranch
        OutputPath = [string]$outputPath
    }
}

# ─────────────────────────────────────────────
# Region: Preflight
# ─────────────────────────────────────────────

function Test-Preflight {
    Write-Phase "PREFLIGHT" "Checking prerequisites"

    # Copilot CLI
    $copilotPath = Get-Command copilot -ErrorAction SilentlyContinue
    if (-not $copilotPath) {
        throw "copilot CLI not found. Install: npm install -g @anthropic/copilot-cli (or GitHub Copilot CLI)"
    }
    $copilotVersion = (& copilot --version 2>&1 | Select-Object -First 1)
    Write-Step "Copilot CLI: $copilotVersion ($($copilotPath.Source))" "OK"

    # Git
    $gitPath = Get-Command git -ErrorAction SilentlyContinue
    if (-not $gitPath) { throw "git not found" }
    $gitVersion = (& git --version 2>&1 | Select-Object -First 1)
    Write-Step "Git: $gitVersion" "OK"

    # PowerShell version
    if ($PSVersionTable.PSVersion.Major -lt 7) {
        Write-Step "PowerShell 7+ recommended (current: $($PSVersionTable.PSVersion))" "WARN"
    }
    else {
        Write-Step "PowerShell: $($PSVersionTable.PSVersion)" "OK"
    }
}

# ─────────────────────────────────────────────
# Region: Pre-Validation
# ─────────────────────────────────────────────

function Test-CopilotInRepo {
    param(
        [string]$WorkingDirectory,
        [switch]$NonInteractive
    )

    Write-Phase "PRE-VALIDATION" "Verifying Copilot & Self-Healing in repo context"

    # Check 1: Basic invocation
    Write-Step "Check 1/3: Testing basic copilot -p invocation..." "INFO"
    $basic = Invoke-CopilotWithRetry -Prompt "Respond with only the word: VALIDATED" -WorkingDirectory $WorkingDirectory -Retries 1 -BaseDelay 5 -Timeout 120
    if (-not $basic.Success) {
        Write-Step "copilot -p FAILED. Error: $($basic.Error)" "ERROR"
        throw "Pre-validation failed: copilot -p does not work in $WorkingDirectory"
    }
    if ($basic.Output -notmatch 'VALIDATED') {
        Write-Step "copilot -p responded but output unexpected: $($basic.Output.Substring(0, [Math]::Min(80, $basic.Output.Length)))" "WARN"
    }
    else {
        Write-Step "copilot -p works ✓" "OK"
    }

    # Check 2: Custom instructions
    Write-Step "Check 2/3: Verifying custom instructions are loaded..." "INFO"
    $instructionCheck = Invoke-CopilotWithRetry -Prompt "List the custom instruction files you loaded for this repo. Output ONLY the filenames, one per line. If none, say NONE." -WorkingDirectory $WorkingDirectory -Retries 1 -BaseDelay 5 -Timeout 120
    if ($instructionCheck.Success) {
        $instrOutput = $instructionCheck.Output
        if ($instrOutput -match 'NONE' -or [string]::IsNullOrWhiteSpace($instrOutput)) {
            Write-Step "No custom instructions detected. Self-healing may not trigger!" "WARN"
            if (-not $NonInteractive) {
                $continue = Read-Host "    Continue anyway? [Y/n]"
                if ($continue -match '^[Nn]') {
                    throw "Aborted: No custom instructions found."
                }
            }
            else {
                Write-Step "Non-interactive: continuing without custom instructions" "INFO"
            }
        }
        else {
            $fileCount = @($instrOutput -split "`n" | Where-Object { $_.Trim() }).Count
            Write-Step "Custom instructions loaded ($fileCount files) ✓" "OK"
            foreach ($line in @($instrOutput -split "`n" | Where-Object { $_.Trim() } | Select-Object -First 10)) {
                Write-Host "    → $($line.Trim())" -ForegroundColor DarkGray
            }
        }
    }
    else {
        Write-Step "Could not verify instructions (non-fatal): $($instructionCheck.Error)" "WARN"
    }

    # Check 3: Deferred to execution
    Write-Step "Check 3/3: Self-healing will be verified during execution (tracking per question)" "OK"
    Write-Step "Pre-validation complete" "OK"
}

# ─────────────────────────────────────────────
# Region: Model Auto-Selection
# ─────────────────────────────────────────────

function Select-MonkeyModel {
    param(
        [string]$UserModel,
        [string]$WorkingDirectory,
        [switch]$NonInteractive
    )

    if ($UserModel) {
        Write-Step "Using user-specified model: $UserModel" "OK"
        return $UserModel
    }

    Write-Step "Auto-detecting best available model..." "INFO"
    foreach ($model in $script:MODEL_PRIORITY) {
        Write-Step "Probing $model..." "INFO"
        $probe = Invoke-CopilotWithRetry -Prompt "Respond with only: OK" -ModelName $model -WorkingDirectory $WorkingDirectory -Retries 0 -BaseDelay 5 -Timeout 120
        if ($probe.Success -and $probe.Output -match 'OK') {
            Write-Step "Model available: $model ✓" "OK"
            if (-not $NonInteractive) {
                Write-Host ""
                $override = Read-Host "  Use ${model}? (Enter to accept, or type model name to override)"
                if (-not [string]::IsNullOrWhiteSpace($override)) {
                    Write-Step "User override: $override" "OK"
                    return $override
                }
            }
            return $model
        }
        Write-Step "$model not available, trying next..." "WARN"
    }

    Write-Step "No preferred models available. Using copilot default." "WARN"
    return $null
}

# ─────────────────────────────────────────────
# Region: Commit / Stage
# ─────────────────────────────────────────────

function Invoke-MonkeyCommit {
    param(
        [string]$WorkingDirectory,
        [string]$OutputDirName,
        [string]$MonkeyName,
        [string]$MonkeyEmoji,
        [string]$BranchName,
        [string]$ModelName,
        [int]$QuestionsAnswered,
        [switch]$DryRun,
        [switch]$Commit
    )

    Write-Phase "PHASE 5" "Commit / Stage"

    Push-Location $WorkingDirectory

    try {
        $changes = & git --no-pager status --porcelain 2>&1
        $changedFiles = @($changes | Where-Object { $_ -and $_ -notmatch '^\?\?' -and $_ -notmatch $OutputDirName }).Count
        $newFiles = @($changes | Where-Object { $_ -match '^\?\?' -and $_ -notmatch $OutputDirName }).Count

        Write-Step "Changed files: $changedFiles | New files: $newFiles" "INFO"

        if (($changedFiles + $newFiles) -eq 0) {
            Write-Step "No documentation changes detected." "WARN"
            return 0
        }

        & git add -A 2>&1 | Out-Null
        $outputPath = Join-Path $WorkingDirectory $OutputDirName
        & git reset -- $outputPath 2>&1 | Out-Null

        $stagedCount = (& git --no-pager diff --cached --name-only 2>&1 | Measure-Object).Count

        if ($stagedCount -eq 0) {
            Write-Step "No files to commit after filtering." "WARN"
            return 0
        }

        Write-Step "Staged $stagedCount files" "OK"
        $stagedFiles = & git --no-pager diff --cached --name-only 2>&1
        foreach ($f in $stagedFiles) {
            Write-Host "    + $f" -ForegroundColor Green
        }

        if ($DryRun) {
            Write-Step "DRY RUN — changes staged but NOT committed." "WARN"
            return $stagedCount
        }

        if ($Commit) {
            $commitMsg = @"
docs: $MonkeyName $MonkeyEmoji auto-generated documentation

Auto-generated by $MonkeyName autonomous doc-generation tool.
Branch: $BranchName
Model: $ModelName
Questions answered: $QuestionsAnswered

Co-authored-by: Copilot <223556219+Copilot@users.noreply.github.com>
"@
            & git commit -m $commitMsg 2>&1 | Out-Null
            if ($LASTEXITCODE -ne 0) {
                Write-Step "Commit failed!" "ERROR"
                return $stagedCount
            }
            Write-Step "Committed to '$BranchName'" "OK"
        }
        else {
            Write-Step "Changes staged. Use -Commit or -DryRun to control behavior." "WARN"
        }

        return $stagedCount
    }
    finally {
        Pop-Location
    }
}

# ─────────────────────────────────────────────
# Region: Question Execution (Phase 4 shared loop)
# ─────────────────────────────────────────────

function Invoke-MonkeyQuestions {
    <#
    .SYNOPSIS
        Shared Phase 4: feeds questions to copilot, tracks doc refs + file changes per answer.
        Supports batch mode (multiple questions per CLI call) with automatic fallback to single mode.
    .PARAMETER BatchSize
        Number of questions per batch. Default 5. Set to 0 or 1 for legacy single-question mode.
    #>
    param(
        [array]$Questions,
        [string]$WorkingDirectory,
        [string]$OutputPath,
        [string]$ModelName,
        [string]$MonkeyEmoji = "🐵",
        [int]$MaxRetries = 3,
        [int]$RetryBaseDelay = 30,
        [int]$CallTimeout = 300,
        [int]$BatchSize = 5,
        [switch]$ShowVerbose
    )

    $useBatch = $BatchSize -ge 2
    $modeLabel = if ($useBatch) { "batch mode (size=$BatchSize)" } else { "single mode" }
    Write-Phase "PHASE 4" "Execution — Asking Copilot ($($Questions.Count) questions, $modeLabel)"

    $stats = @{
        Answered         = 0
        Failed           = 0
        Retries          = 0
        FileChanges      = 0
        DocGroundedCount = 0
        HealingQuestions = @()
        QuestionDetails  = @()
        BatchesRun       = 0
        BatchesFailed    = 0
        FallbackSingles  = 0
    }
    $failedQuestions = @()

    # Assign stable IDs to each question
    foreach ($q in $Questions) {
        $q['QuestionId'] = Get-QuestionId -EntryPoint $q.EntryPoint -Question $q.Question
    }

    # Load checkpoint — skip already-completed questions
    $completedIds = Get-BatchCheckpoint -OutputPath $OutputPath
    if ($completedIds.Count -gt 0) {
        $beforeCount = $Questions.Count
        $Questions = @($Questions | Where-Object { -not $completedIds.Contains($_.QuestionId) })
        Write-Step "Checkpoint: $($completedIds.Count) already done, $($Questions.Count)/$beforeCount remaining" "OK"
    }

    $totalQ = $Questions.Count
    if ($totalQ -eq 0) {
        Write-Step "All questions already completed (checkpoint)" "OK"
        return $stats
    }

    New-Item -ItemType Directory -Path (Join-Path $OutputPath "session-logs") -Force | Out-Null
    Push-Location $WorkingDirectory

    try {
        if ($useBatch) {
            # ═══════════════════════════════════════════
            # BATCH MODE
            # ═══════════════════════════════════════════
            $batches = [System.Collections.ArrayList]::new()
            for ($i = 0; $i -lt $totalQ; $i += $BatchSize) {
                $end = [Math]::Min($i + $BatchSize, $totalQ)
                $batch = @($Questions[$i..($end - 1)])
                # Assign batch-local indices
                $bIdx = 0
                foreach ($bq in $batch) { $bq['BatchIndex'] = ++$bIdx }
                [void]$batches.Add($batch)
            }

            $batchNum = 0
            $processedQ = $completedIds.Count

            foreach ($batch in $batches) {
                $batchNum++
                $processedQ += $batch.Count
                $pct = [Math]::Round(($processedQ / ($totalQ + $completedIds.Count)) * 100)
                Write-Progress -Activity "$MonkeyEmoji batch execution" -Status "Batch $batchNum/$($batches.Count) ($processedQ questions)" -PercentComplete $pct

                $beforeStatus = & git --no-pager status --porcelain 2>&1

                $sharePath = Join-Path $OutputPath "session-logs" ("batch-{0:D3}.md" -f $batchNum)
                $batchResult = Invoke-CopilotBatch `
                    -Questions $batch `
                    -WorkingDirectory $WorkingDirectory `
                    -OutputPath $OutputPath `
                    -ModelName $ModelName `
                    -SharePath $sharePath `
                    -Retries $MaxRetries `
                    -BaseDelay $RetryBaseDelay `
                    -TimeoutPerQuestion $CallTimeout `
                    -ShowVerbose:$ShowVerbose

                $stats.BatchesRun++
                $stats.Retries += $batchResult.Retries

                # File changes at batch level
                $afterStatus = & git --no-pager status --porcelain 2>&1
                $batchFileChanges = @($afterStatus | Where-Object { $_ -notin $beforeStatus })

                if ($batchResult.Status -eq "FAILED") {
                    # Entire batch failed — fall back to single-question mode for this batch
                    $stats.BatchesFailed++
                    Write-Step "Batch $batchNum failed — falling back to single mode for $($batch.Count) questions" "WARN"

                    foreach ($q in $batch) {
                        $stats.FallbackSingles++
                        $singleResult = Invoke-SingleQuestion -Question $q -WorkingDirectory $WorkingDirectory -OutputPath $OutputPath -ModelName $ModelName -MaxRetries $MaxRetries -RetryBaseDelay $RetryBaseDelay -CallTimeout $CallTimeout -ShowVerbose:$ShowVerbose -Stats $stats -FailedQuestions ([ref]$failedQuestions) -GlobalIndex ($processedQ - $batch.Count + $q.BatchIndex)
                        [void]$completedIds.Add($q.QuestionId)
                    }
                    Save-BatchCheckpoint -OutputPath $OutputPath -CompletedIds $completedIds
                    continue
                }

                # Process each question result from the batch
                foreach ($qr in $batchResult.QuestionResults) {
                    if ($qr.Success) {
                        $stats.Answered++
                        $docRefs = Get-DocReferences -ResponseText $qr.Output
                        if ($docRefs.IsDocGrounded) { $stats.DocGroundedCount++ }

                        # File changes attributed at batch level
                        $hasFileChanges = $batchFileChanges.Count -gt 0

                        $verdict = switch ($true) {
                            ($docRefs.IsDocGrounded -and $hasFileChanges) { "DOCS_REFERENCED+FILES_CHANGED" }
                            ($docRefs.IsDocGrounded)                      { "DOCS_REFERENCED" }
                            ($hasFileChanges)                             { "FILES_CHANGED" }
                            default                                       { "NO_DOC_SIGNAL" }
                        }

                        $stats.QuestionDetails += @{
                            Index        = $processedQ - $batch.Count + $qr.BatchIndex
                            EntryPoint   = $qr.EntryPoint
                            Question     = $qr.Question
                            Category     = if ($qr.Category) { $qr.Category } else { 'general' }
                            Verdict      = $verdict
                            DocGrounded  = $docRefs.IsDocGrounded
                            DocPaths     = $docRefs.DocPaths
                            DocRefCount  = $docRefs.TotalRefs
                            FileChanges  = 0  # batch-level — not per-question
                            BatchMode    = $true
                        }
                        [void]$completedIds.Add($qr.QuestionId)
                        Write-Step "  Q$($qr.BatchIndex) ✓ ($verdict)" "OK"
                    }
                    else {
                        # Individual question failed in batch — retry as single
                        $stats.FallbackSingles++
                        Write-Step "  Q$($qr.BatchIndex) failed in batch — retrying single" "WARN"
                        $origQ = $batch | Where-Object { $_.QuestionId -eq $qr.QuestionId }
                        if ($origQ) {
                            Invoke-SingleQuestion -Question $origQ -WorkingDirectory $WorkingDirectory -OutputPath $OutputPath -ModelName $ModelName -MaxRetries $MaxRetries -RetryBaseDelay $RetryBaseDelay -CallTimeout $CallTimeout -ShowVerbose:$ShowVerbose -Stats $stats -FailedQuestions ([ref]$failedQuestions) -GlobalIndex ($processedQ - $batch.Count + $qr.BatchIndex)
                        }
                        else {
                            $stats.Failed++
                        }
                        [void]$completedIds.Add($qr.QuestionId)
                    }
                }

                # Record batch-level file changes
                if ($batchFileChanges.Count -gt 0) {
                    $stats.FileChanges += $batchFileChanges.Count
                    $stats.HealingQuestions += @{
                        Question     = "Batch $batchNum ($($batch.Count) questions)"
                        EntryPoint   = ($batch | ForEach-Object { $_.EntryPoint } | Select-Object -Unique) -join ", "
                        FilesChanged = $batchFileChanges.Count
                        Files        = @($batchFileChanges | ForEach-Object { $_.Trim() })
                    }
                    Write-Step "Batch ${batchNum}: $($batchFileChanges.Count) file(s) changed (self-healing!)" "OK"
                }

                Save-BatchCheckpoint -OutputPath $OutputPath -CompletedIds $completedIds
            }
        }
        else {
            # ═══════════════════════════════════════════
            # SINGLE MODE (legacy)
            # ═══════════════════════════════════════════
            $currentQ = 0
            foreach ($q in $Questions) {
                $currentQ++
                Invoke-SingleQuestion -Question $q -WorkingDirectory $WorkingDirectory -OutputPath $OutputPath -ModelName $ModelName -MaxRetries $MaxRetries -RetryBaseDelay $RetryBaseDelay -CallTimeout $CallTimeout -ShowVerbose:$ShowVerbose -Stats $stats -FailedQuestions ([ref]$failedQuestions) -GlobalIndex $currentQ -TotalQ $totalQ -MonkeyEmoji $MonkeyEmoji
                [void]$completedIds.Add($q.QuestionId)
                Save-BatchCheckpoint -OutputPath $OutputPath -CompletedIds $completedIds
            }
        }
    }
    finally {
        Pop-Location
    }

    Write-Progress -Activity "$MonkeyEmoji answering questions" -Completed

    if ($failedQuestions.Count -gt 0) {
        $failedPath = Join-Path $OutputPath "failed-questions.json"
        $failedQuestions | ConvertTo-Json -Depth 5 | Set-Content $failedPath -Encoding UTF8
        Write-Step "$($failedQuestions.Count) failed questions saved to failed-questions.json" "WARN"
    }

    # Batch summary
    if ($useBatch) {
        Write-Step "Batch summary: $($stats.BatchesRun) batches, $($stats.BatchesFailed) failed, $($stats.FallbackSingles) fallback singles" "INFO"
    }

    return $stats
}

function Invoke-SingleQuestion {
    <#
    .SYNOPSIS
        Executes a single question against copilot and updates stats.
        Extracted to share between batch fallback and legacy single mode.
    #>
    param(
        [hashtable]$Question,
        [string]$WorkingDirectory,
        [string]$OutputPath,
        [string]$ModelName,
        [int]$MaxRetries = 3,
        [int]$RetryBaseDelay = 30,
        [int]$CallTimeout = 300,
        [switch]$ShowVerbose,
        [hashtable]$Stats,
        [ref]$FailedQuestions,
        [int]$GlobalIndex = 0,
        [int]$TotalQ = 0,
        [string]$MonkeyEmoji = "🐵"
    )

    $q = $Question
    if ($TotalQ -gt 0) {
        $pct = [Math]::Round(($GlobalIndex / $TotalQ) * 100)
        $entryLabel = if ($q.EntryPoint) { $q.EntryPoint } else { "general" }
        Write-Progress -Activity "$MonkeyEmoji answering questions" -Status "$GlobalIndex/$TotalQ — $entryLabel" -PercentComplete $pct
    }

    $beforeStatus = & git --no-pager status --porcelain 2>&1

    $docHealSuffix = " If relevant documentation for this topic is missing or incomplete in the repo, create or update it following existing doc patterns."
    $prompt = if ($q.EntryPoint) {
        "Regarding the file '$($q.EntryPoint)': $($q.Question)$docHealSuffix"
    } else {
        "$($q.Question)$docHealSuffix"
    }

    $safeName = if ($q.EntryPoint) {
        ($q.EntryPoint -replace '[\\/:*?"<>|]', '_') -replace '\.cs$|\.py$|\.java$|\.go$|\.ts$|\.js$', ''
    } else {
        "general_$GlobalIndex"
    }
    $sharePath = Join-Path $OutputPath "session-logs" ("{0:D3}-{1}.md" -f $GlobalIndex, $safeName)

    Write-Step "[$GlobalIndex] $($q.Question.Substring(0, [Math]::Min(80, $q.Question.Length)))..." "INFO"

    $result = Invoke-CopilotWithRetry -Prompt $prompt -ModelName $ModelName -SharePath $sharePath -WorkingDirectory $WorkingDirectory -Retries $MaxRetries -BaseDelay $RetryBaseDelay -Timeout $CallTimeout -ShowVerbose:$ShowVerbose

    $Stats.Retries += $result.Retries

    if ($result.Success) {
        $Stats.Answered++

        $docRefs = Get-DocReferences -ResponseText $result.Output
        if ($docRefs.IsDocGrounded) { $Stats.DocGroundedCount++ }

        # Also parse transcript
        if (Test-Path $sharePath) {
            $transcript = Get-Content $sharePath -Raw -ErrorAction SilentlyContinue
            if ($transcript) {
                $transcriptRefs = Get-DocReferences -ResponseText $transcript
                if ($transcriptRefs.IsDocGrounded -and -not $docRefs.IsDocGrounded) {
                    $docRefs = $transcriptRefs
                    $Stats.DocGroundedCount++
                }
                elseif ($transcriptRefs.IsDocGrounded) {
                    $docRefs = $transcriptRefs
                }
            }
        }

        $afterStatus = & git --no-pager status --porcelain 2>&1
        $newChanges = @($afterStatus | Where-Object { $_ -notin $beforeStatus })
        $hasFileChanges = $newChanges.Count -gt 0

        if ($hasFileChanges) {
            $Stats.FileChanges += $newChanges.Count
            $Stats.HealingQuestions += @{
                Question     = $q.Question
                EntryPoint   = $q.EntryPoint
                FilesChanged = $newChanges.Count
                Files        = @($newChanges | ForEach-Object { $_.Trim() })
            }
        }

        $verdict = switch ($true) {
            ($docRefs.IsDocGrounded -and $hasFileChanges) { "DOCS_REFERENCED+FILES_CHANGED" }
            ($docRefs.IsDocGrounded -and -not $hasFileChanges) { "DOCS_REFERENCED" }
            (-not $docRefs.IsDocGrounded -and $hasFileChanges) { "FILES_CHANGED" }
            default { "NO_DOC_SIGNAL" }
        }

        $Stats.QuestionDetails += @{
            Index        = $GlobalIndex
            EntryPoint   = $q.EntryPoint
            Question     = $q.Question
            Category     = if ($q.ContainsKey('Category')) { $q.Category } else { 'general' }
            Verdict      = $verdict
            DocGrounded  = $docRefs.IsDocGrounded
            DocPaths     = $docRefs.DocPaths
            DocRefCount  = $docRefs.TotalRefs
            FileChanges  = $newChanges.Count
            BatchMode    = $false
        }

        if ($hasFileChanges) {
            Write-Step "Answered ✓ + $($newChanges.Count) file(s) changed (self-healing triggered!)" "OK"
            foreach ($change in $newChanges | Select-Object -First 5) {
                Write-Host "      $change" -ForegroundColor Green
            }
        }
        elseif ($docRefs.IsDocGrounded) {
            Write-Step "Answered ✓ (refs $($docRefs.DocPaths.Count) docs — docs already complete)" "OK"
        }
        else {
            Write-Step "Answered ✓ (no doc signal)" "WARN"
        }
    }
    else {
        $Stats.Failed++
        $FailedQuestions.Value += @{
            EntryPoint = $q.EntryPoint
            Question   = $q.Question
            Error      = $result.Error
        }
        Write-Step "FAILED: $($result.Error)" "ERROR"
    }
}

# ─────────────────────────────────────────────
# Region: Report Generation
# ─────────────────────────────────────────────

function Save-MonkeyReport {
    param(
        [hashtable]$ExecStats,
        [string]$OutputPath,
        [string]$MonkeyName
    )

    $docGroundedPct = if ($ExecStats.Answered -gt 0) {
        [Math]::Round(($ExecStats.DocGroundedCount / $ExecStats.Answered) * 100, 1)
    } else { 0 }
    $noSignalCount = @($ExecStats.QuestionDetails | Where-Object { $_.Verdict -eq "NO_DOC_SIGNAL" }).Count

    # Healing report
    $healingReport = @{
        MonkeyName = $MonkeyName
        Summary = @{
            TotalAnswered       = $ExecStats.Answered
            DocGroundedCount    = $ExecStats.DocGroundedCount
            DocGroundedPct      = $docGroundedPct
            FileChangesTotal    = $ExecStats.FileChanges
            HealingTriggered    = $ExecStats.HealingQuestions.Count
            NoDocSignalCount    = $noSignalCount
        }
        Verdicts = @{
            DOCS_REFERENCED_FILES_CHANGED = @($ExecStats.QuestionDetails | Where-Object { $_.Verdict -eq "DOCS_REFERENCED+FILES_CHANGED" }).Count
            DOCS_REFERENCED               = @($ExecStats.QuestionDetails | Where-Object { $_.Verdict -eq "DOCS_REFERENCED" }).Count
            FILES_CHANGED                 = @($ExecStats.QuestionDetails | Where-Object { $_.Verdict -eq "FILES_CHANGED" }).Count
            NO_DOC_SIGNAL                 = $noSignalCount
        }
        QuestionDetails     = $ExecStats.QuestionDetails
        HealingQuestions    = $ExecStats.HealingQuestions
    }
    $healingReport | ConvertTo-Json -Depth 5 | Set-Content (Join-Path $OutputPath "healing-report.json") -Encoding UTF8

    # Coverage by entry point
    $epCoverage = $ExecStats.QuestionDetails | Group-Object EntryPoint | ForEach-Object {
        $grounded = @($_.Group | Where-Object { $_.DocGrounded }).Count
        @{
            EntryPoint             = $_.Name
            TotalQuestions         = $_.Count
            DocGrounded            = $grounded
            CoveragePct            = if ($_.Count -gt 0) { [Math]::Round(($grounded / $_.Count) * 100, 1) } else { 0 }
            UniqueDocsReferenced   = @($_.Group | ForEach-Object { $_.DocPaths } | Sort-Object -Unique)
        }
    }
    $epCoverage | ConvertTo-Json -Depth 5 | Set-Content (Join-Path $OutputPath "doc-coverage-by-entrypoint.json") -Encoding UTF8

    # Display
    Write-Host "  Doc-Grounded Answers: $($ExecStats.DocGroundedCount)/$($ExecStats.Answered) ($docGroundedPct%)" -ForegroundColor $(if ($docGroundedPct -ge 70) { 'Green' } elseif ($docGroundedPct -ge 40) { 'Yellow' } else { 'Red' })
    Write-Host "  Reports: healing-report.json, doc-coverage-by-entrypoint.json" -ForegroundColor Cyan

    return @{
        DocGroundedPct   = $docGroundedPct
        NoDocSignalCount = $noSignalCount
    }
}

# ─────────────────────────────────────────────
# Region: Standardized Monkey Result
# ─────────────────────────────────────────────

function New-MonkeyResult {
    <#
    .SYNOPSIS
        Creates a standardized result object that every monkey returns.
        Ensures uniform shape for orchestrator consumption.
    #>
    param(
        [Parameter(Mandatory)][string]$MonkeyName,
        [TimeSpan]$Duration,
        [string]$Model,
        [ValidateSet('SUCCESS','PARTIAL','FAILED','SKIPPED')]
        [string]$ExitStatus = 'SUCCESS',
        [int]$QuestionsAsked      = 0,
        [int]$QuestionsAnswered   = 0,
        [int]$DocRefsFound        = 0,
        [int]$FilesCreated        = 0,
        [int]$FilesModified       = 0,
        [double]$DocsGroundedPct  = 0,
        [int]$RetryCount          = 0,
        [string[]]$Errors         = @()
    )

    return @{
        MonkeyName        = $MonkeyName
        Duration          = if ($Duration) { $Duration.ToString('hh\:mm\:ss') } else { '00:00:00' }
        DurationSeconds   = if ($Duration) { [int]$Duration.TotalSeconds } else { 0 }
        Model             = $Model
        ExitStatus        = $ExitStatus
        QuestionsAsked    = $QuestionsAsked
        QuestionsAnswered = $QuestionsAnswered
        DocRefsFound      = $DocRefsFound
        FilesCreated      = $FilesCreated
        FilesModified     = $FilesModified
        DocsGroundedPct   = $DocsGroundedPct
        RetryCount        = $RetryCount
        Errors            = $Errors
        Timestamp         = (Get-Date).ToString('o')
    }
}

# ─────────────────────────────────────────────
# Region: Agent-Mode Invocation
# ─────────────────────────────────────────────

function Start-AgentMonkey {
    <#
    .SYNOPSIS
        Launches copilot in agent mode (autonomous, multi-hour) with a prompt file.
        Used by Playbook and Curious George.
    .RETURNS
        Hashtable: @{ Success; Output; Duration; SharePath }
    #>
    param(
        [Parameter(Mandatory)][string]$PromptText,
        [Parameter(Mandatory)][string]$WorkingDirectory,
        [string]$ModelName,
        [int]$Timeout = 7200,   # 2h default for agent mode
        [string]$SharePath
    )

    $copilotArgs = @("--prompt", $PromptText, "--allow-all", "--autopilot", "--no-ask-user")
    if ($ModelName) { $copilotArgs += @("--model", $ModelName) }
    if ($SharePath) { $copilotArgs += @("--share=$SharePath") }

    $startTime = Get-Date

    $job = Start-Job -ScriptBlock {
        param($wd, $args_)
        Set-Location $wd
        $output = & copilot @args_ 2>&1
        @{ ExitCode = $LASTEXITCODE; Output = ($output | Out-String).Trim() }
    } -ArgumentList $WorkingDirectory, $copilotArgs

    $completed = $job | Wait-Job -Timeout $Timeout
    $elapsed = (Get-Date) - $startTime

    if (-not $completed) {
        $job | Stop-Job -ErrorAction SilentlyContinue
        $partialOutput = try { $job | Receive-Job -ErrorAction SilentlyContinue | ForEach-Object { $_.Output } } catch { '' }
        $job | Remove-Job -Force -ErrorAction SilentlyContinue
        return @{
            Success   = $false
            Output    = $partialOutput
            Error     = "TIMEOUT after $($Timeout)s"
            Duration  = $elapsed
            SharePath = $SharePath
        }
    }

    $jobResult = $job | Receive-Job
    $job | Remove-Job -Force -ErrorAction SilentlyContinue

    return @{
        Success   = ($jobResult.ExitCode -eq 0 -or $null -eq $jobResult.ExitCode)
        Output    = $jobResult.Output
        Error     = if ($jobResult.ExitCode -ne 0) { "Exit code $($jobResult.ExitCode)" } else { $null }
        Duration  = $elapsed
        SharePath = $SharePath
    }
}

function Read-AgentStatus {
    <#
    .SYNOPSIS
        Parses machine-readable MONKEY_STATUS block from agent-mode output.
    .RETURNS
        Hashtable with parsed status fields, or $null if no block found.
    #>
    param([string]$Output)

    if (-not $Output) { return $null }

    $status = @{}
    $patterns = @{
        'Status'         = 'MONKEY_STATUS:\s*(SUCCESS|PARTIAL|FAILED)'
        'DocsCreated'    = 'DOCS_CREATED:\s*(\d+)'
        'DocsUpdated'    = 'DOCS_UPDATED:\s*(\d+)'
        'QuestionsAsked' = 'QUESTIONS_ASKED:\s*(\d+)'
        'GapsFound'      = 'GAPS_FOUND:\s*(\d+)'
        'GapsFixed'      = 'GAPS_FIXED:\s*(\d+)'
    }

    foreach ($key in $patterns.Keys) {
        $m = [regex]::Match($Output, $patterns[$key])
        if ($m.Success) {
            $val = $m.Groups[1].Value
            $status[$key] = if ($val -match '^\d+$') { [int]$val } else { $val }
        }
    }

    if ($status.Count -eq 0) { return $null }
    return $status
}

# ─────────────────────────────────────────────
# Region: Unified Input Wizard (Get-ArmyConfig)
# ─────────────────────────────────────────────

# Monkey pack definitions
$script:MonkeyPacks = @{
    'audit'      = @('rafiki', 'abu', 'mojo-jojo')
    'security'   = @('mojo-jojo', 'king-louie')
    'docs'       = @('playbook', 'rafiki', 'abu', 'marcel')
    'full'       = @('playbook', 'rafiki', 'abu', 'diddy-kong', 'king-louie', 'mojo-jojo', 'donkey-kong', 'marcel', 'curious-george')
    'autonomous' = @('playbook', 'curious-george')
    'quick'      = @('rafiki', 'abu')
}

$script:AllMonkeys = @(
    @{ Id = 'playbook';       Name = 'Playbook';       Emoji = '📋'; Mode = 'agent';  Phase = 0; Desc = 'Generate knowledge layer foundation' }
    @{ Id = 'rafiki';         Name = 'Rafiki';         Emoji = '🐒'; Mode = 'prompt'; Phase = 1; Desc = 'Read code entry points, broad questions' }
    @{ Id = 'abu';            Name = 'Abu';            Emoji = '🐵'; Mode = 'prompt'; Phase = 2; Desc = 'Find and fill documentation gaps' }
    @{ Id = 'diddy-kong';     Name = 'Diddy Kong';     Emoji = '🐒'; Mode = 'prompt'; Phase = 3; Desc = 'Map architecture & dependencies' }
    @{ Id = 'king-louie';     Name = 'King Louie';     Emoji = '👑'; Mode = 'prompt'; Phase = 4; Desc = 'Validate API contracts vs code' }
    @{ Id = 'mojo-jojo';      Name = 'Mojo Jojo';      Emoji = '🦹'; Mode = 'prompt'; Phase = 5; Desc = 'Security, edge cases, crash patterns' }
    @{ Id = 'donkey-kong';    Name = 'Donkey Kong';     Emoji = '🦍'; Mode = 'prompt'; Phase = 6; Desc = 'Find untested code & coverage gaps' }
    @{ Id = 'marcel';         Name = 'Marcel';          Emoji = '🙈'; Mode = 'prompt'; Phase = 7; Desc = 'Detect stale/dead doc references' }
    @{ Id = 'curious-george'; Name = 'Curious George';  Emoji = '🐵'; Mode = 'agent';  Phase = 8; Desc = 'Deep 3-pass autonomous audit' }
)

function Get-ArmyConfig {
    <#
    .SYNOPSIS
        Unified input wizard. Collects ALL inputs upfront for the entire run.
        Returns a config hashtable consumed by the orchestrator and passed to each monkey.
        When -NonInteractive is set, uses defaults + explicit params (for CI/CD).
    #>
    param(
        # ── Pre-filled values (skip prompts for these) ──
        [string]$RepoUrl,
        [string]$RepoPath,
        [string]$ClonePath,
        [string]$BaseBranch,
        [string]$BranchName,
        [switch]$UseBaseBranch,
        [string]$Model,
        [string]$Pack,
        [string[]]$Monkeys,
        [string]$CommitMode,         # 'dry-run' | 'commit' | 'stage'
        [switch]$CreatePR,
        [string]$GitProvider,        # 'ado' | 'github' | 'gitlab' | 'git'
        [int]$QuestionsPerEntry,
        [int]$QuestionsPerGap,
        [int]$QuestionsPerFile,
        [string[]]$TargetAgents,     # AI agents to score: copilot, cursor, claude, coderabbit, aider, windsurf
        # ── Curious George specifics ──
        [int]$GeorgeQuestionsPerDomain,
        [string]$GeorgeFocusArea,
        [string]$GeorgeDifficulty,
        [int]$GeorgeMaxSkip,
        [string]$GeorgeFixMode,
        [string]$GeorgeDiscoveryMode,
        # ── Behavior ──
        [switch]$NonInteractive
    )

    $config = @{}

    # ═══════════════════════════════════════════
    # GROUP 1: REPOSITORY
    # ═══════════════════════════════════════════
    Write-Host ""
    Write-Host "  ╔══════════════════════════════════════════╗" -ForegroundColor Magenta
    Write-Host "  ║  🐒 MONKEY ARMY — Mission Briefing       ║" -ForegroundColor Magenta
    Write-Host "  ╚══════════════════════════════════════════╝" -ForegroundColor Magenta
    Write-Host ""

    # Q1: Repo source
    if ($RepoPath) {
        $config.RepoPath = $RepoPath
        $config.RepoUrl  = $null
        Write-Step "Repo: $RepoPath (local)" "OK"
    }
    elseif ($RepoUrl) {
        $config.RepoUrl = $RepoUrl
        if (-not $ClonePath) {
            if ($NonInteractive) { $ClonePath = ".\monkey-workspace" }
            else {
                Write-Host "  📁 Where should we clone?" -ForegroundColor Cyan
                $ClonePath = Read-Host "     Clone path (default: .\monkey-workspace)"
                if ([string]::IsNullOrWhiteSpace($ClonePath)) { $ClonePath = ".\monkey-workspace" }
            }
        }
        $config.ClonePath = $ClonePath
        Write-Step "Repo: $RepoUrl → $ClonePath" "OK"
    }
    else {
        if ($NonInteractive) { throw "Either -RepoUrl or -RepoPath required in non-interactive mode." }
        Write-Host "  📦 Repository source:" -ForegroundColor Cyan
        Write-Host "    [1] Local path (already cloned)" -ForegroundColor DarkGray
        Write-Host "    [2] Git URL (will clone)" -ForegroundColor DarkGray
        $choice = Read-Host "     Choose (default: 1)"
        if ($choice -eq '2') {
            $config.RepoUrl = Read-Host "     Git URL"
            $cp = Read-Host "     Clone path (default: .\monkey-workspace)"
            $config.ClonePath = if ([string]::IsNullOrWhiteSpace($cp)) { ".\monkey-workspace" } else { $cp }
        }
        else {
            $config.RepoPath = Read-Host "     Path to repo"
            if (-not (Test-Path $config.RepoPath)) { throw "Path '$($config.RepoPath)' not found." }
        }
    }

    # Q2: Base branch
    if (-not $BaseBranch -and -not $NonInteractive) {
        $detectDir = if ($config.RepoPath) { $config.RepoPath } else { $null }
        if ($detectDir -and (Test-Path $detectDir)) {
            Push-Location $detectDir
            $branches = @(& git --no-pager branch -r 2>&1 | ForEach-Object { $_.Trim() -replace '^origin/', '' } | Where-Object { $_ -and $_ -notmatch 'HEAD' } | Select-Object -First 15)
            Pop-Location
            if ($branches.Count -gt 0) {
                Write-Host "  🌿 Remote branches:" -ForegroundColor Cyan
                for ($i = 0; $i -lt $branches.Count; $i++) {
                    Write-Host "    [$i] $($branches[$i])" -ForegroundColor DarkGray
                }
            }
        }
        $input_ = Read-Host "     Base branch (default: main)"
        if ([string]::IsNullOrWhiteSpace($input_)) { $BaseBranch = "main" }
        elseif ($branches -and $input_ -match '^\d+$' -and [int]$input_ -lt $branches.Count) {
            $BaseBranch = $branches[[int]$input_]
        }
        else { $BaseBranch = $input_ }
    }
    $config.BaseBranch = if ($BaseBranch) { $BaseBranch } else { "main" }
    Write-Step "Base branch: $($config.BaseBranch)" "OK"

    # ═══════════════════════════════════════════
    # GROUP 2: EXECUTION
    # ═══════════════════════════════════════════
    Write-Host ""

    # Q3: Pack / monkey selection
    if ($Pack) {
        if (-not $script:MonkeyPacks.ContainsKey($Pack)) {
            throw "Unknown pack '$Pack'. Available: $($script:MonkeyPacks.Keys -join ', ')"
        }
        $config.SelectedMonkeys = $script:MonkeyPacks[$Pack]
        $config.Pack = $Pack
    }
    elseif ($Monkeys) {
        $config.SelectedMonkeys = $Monkeys
        $config.Pack = 'custom'
    }
    else {
        if ($NonInteractive) {
            $config.SelectedMonkeys = $script:MonkeyPacks['full']
            $config.Pack = 'full'
        }
        else {
            Write-Host "  🐒 Select monkey pack:" -ForegroundColor Cyan
            $packNames = @($script:MonkeyPacks.Keys | Sort-Object)
            for ($i = 0; $i -lt $packNames.Count; $i++) {
                $pName = $packNames[$i]
                $pMonkeys = $script:MonkeyPacks[$pName] -join ', '
                Write-Host "    [$($i+1)] $pName — $pMonkeys" -ForegroundColor DarkGray
            }
            Write-Host "    [$($packNames.Count+1)] custom (pick individual monkeys)" -ForegroundColor DarkGray
            $packChoice = Read-Host "     Choose (default: full)"

            if ($packChoice -match '^\d+$' -and [int]$packChoice -le $packNames.Count) {
                $config.Pack = $packNames[[int]$packChoice - 1]
                $config.SelectedMonkeys = $script:MonkeyPacks[$config.Pack]
            }
            elseif ($packChoice -eq [string]($packNames.Count + 1)) {
                Write-Host "  Available monkeys:" -ForegroundColor Cyan
                foreach ($m in $script:AllMonkeys) {
                    Write-Host "    $($m.Emoji) $($m.Id) — $($m.Desc)" -ForegroundColor DarkGray
                }
                $customInput = Read-Host "     Enter monkey IDs (comma-separated)"
                $config.SelectedMonkeys = @($customInput -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
                $config.Pack = 'custom'
            }
            else {
                $config.Pack = 'full'
                $config.SelectedMonkeys = $script:MonkeyPacks['full']
            }
        }
    }
    $monkeyList = $config.SelectedMonkeys -join ', '
    Write-Step "Pack: $($config.Pack) → [$monkeyList]" "OK"

    # Q4: Branch strategy
    if (-not $UseBaseBranch -and -not $BranchName) {
        if ($NonInteractive) { $BranchName = "monkey-army/$(Get-Date -Format 'yyyyMMdd-HHmmss')" }
        else {
            Write-Host "  🌿 Branch strategy:" -ForegroundColor Cyan
            Write-Host "    [1] Create new branch (recommended)" -ForegroundColor DarkGray
            Write-Host "    [2] Work on '$($config.BaseBranch)' directly" -ForegroundColor DarkGray
            $brChoice = Read-Host "     Choose (default: 1)"
            if ($brChoice -eq '2') { $UseBaseBranch = [switch]::new($true) }
            else {
                $customBr = Read-Host "     Branch name (default: monkey-army/<timestamp>)"
                $BranchName = if ([string]::IsNullOrWhiteSpace($customBr)) {
                    "monkey-army/$(Get-Date -Format 'yyyyMMdd-HHmmss')"
                } else { $customBr }
            }
        }
    }
    $config.UseBaseBranch = [bool]$UseBaseBranch
    $config.BranchName = $BranchName
    Write-Step "Branch: $(if ($UseBaseBranch) { $config.BaseBranch } else { $BranchName })" "OK"

    # Q5: Commit mode
    if (-not $CommitMode) {
        if ($NonInteractive) { $CommitMode = 'commit' }
        else {
            Write-Host "  💾 Commit mode:" -ForegroundColor Cyan
            Write-Host "    [1] commit — auto-commit changes" -ForegroundColor DarkGray
            Write-Host "    [2] dry-run — stage only, don't commit" -ForegroundColor DarkGray
            Write-Host "    [3] stage — git add, no commit" -ForegroundColor DarkGray
            $cmChoice = Read-Host "     Choose (default: 1)"
            $CommitMode = switch ($cmChoice) {
                '2' { 'dry-run' }
                '3' { 'stage' }
                default { 'commit' }
            }
        }
    }
    $config.CommitMode = $CommitMode
    Write-Step "Commit mode: $CommitMode" "OK"

    # Q6: Create PR?
    if (-not $PSBoundParameters.ContainsKey('CreatePR')) {
        if ($NonInteractive) { $CreatePR = [switch]::new($false) }
        elseif ($CommitMode -eq 'commit' -and -not $UseBaseBranch) {
            $prChoice = Read-Host "  📬 Create pull request when done? [Y/n]"
            $CreatePR = [switch]::new($prChoice -notmatch '^[Nn]')
        }
    }
    $config.CreatePR = [bool]$CreatePR
    if ($config.CreatePR) { Write-Step "PR: will create when done" "OK" }

    # Q7: Git provider
    if (-not $GitProvider) {
        $remoteUrl = if ($config.RepoUrl) { $config.RepoUrl }
        elseif ($config.RepoPath -and (Test-Path $config.RepoPath)) {
            Push-Location $config.RepoPath
            $u = & git --no-pager remote get-url origin 2>&1
            Pop-Location
            if ($LASTEXITCODE -eq 0) { $u } else { '' }
        } else { '' }
        $config.GitProvider = Get-GitProvider -RemoteUrl $remoteUrl
    }
    else {
        $config.GitProvider = $GitProvider
    }
    Write-Step "Git provider: $($config.GitProvider)" "OK"

    # ═══════════════════════════════════════════
    # GROUP 3: MODEL
    # ═══════════════════════════════════════════
    Write-Host ""

    $config['Model'] = $null  # Initialize — will auto-detect if not set
    if ($Model) {
        $config['Model'] = $Model
    }
    elseif (-not $NonInteractive) {
        Write-Host "  🤖 Model preference:" -ForegroundColor Cyan
        Write-Host "    [1] Auto-detect (probe best available)" -ForegroundColor DarkGray
        Write-Host "    [2] Specify model name" -ForegroundColor DarkGray
        $mChoice = Read-Host "     Choose (default: 1)"
        if ($mChoice -eq '2') {
            $config['Model'] = Read-Host "     Model name"
        }
        else {
            $config['Model'] = $null  # Will auto-detect during setup
        }
    }
    Write-Step "Model: $(if ($config['Model']) { $config['Model'] } else { 'auto-detect' })" "OK"

    # ═══════════════════════════════════════════
    # GROUP 4: MONKEY TUNING
    # ═══════════════════════════════════════════
    Write-Host ""

    $hasPromptMonkeys = @($config.SelectedMonkeys | Where-Object { $_ -notin @('playbook', 'curious-george') })

    # Only ask tuning questions if relevant monkeys are selected
    if ($hasPromptMonkeys.Count -gt 0) {
        if ($QuestionsPerEntry -gt 0) {
            $config.QuestionsPerEntry = $QuestionsPerEntry
        }
        elseif ('rafiki' -in $config.SelectedMonkeys -and -not $NonInteractive) {
            $qpe = Read-Host "  🐒 Rafiki: questions per entry point (default: 10)"
            $config.QuestionsPerEntry = if ($qpe -match '^\d+$') { [int]$qpe } else { 10 }
        }
        else { $config.QuestionsPerEntry = 10 }

        if ($QuestionsPerGap -gt 0) {
            $config.QuestionsPerGap = $QuestionsPerGap
        }
        elseif ('abu' -in $config.SelectedMonkeys -and -not $NonInteractive) {
            $qpg = Read-Host "  🐵 Abu: questions per doc gap (default: 5)"
            $config.QuestionsPerGap = if ($qpg -match '^\d+$') { [int]$qpg } else { 5 }
        }
        else { $config.QuestionsPerGap = 5 }

        if ($QuestionsPerFile -gt 0) {
            $config.QuestionsPerFile = $QuestionsPerFile
        }
        elseif ('mojo-jojo' -in $config.SelectedMonkeys -and -not $NonInteractive) {
            $qpf = Read-Host "  🦹 Mojo Jojo: questions per risky file (default: 5)"
            $config.QuestionsPerFile = if ($qpf -match '^\d+$') { [int]$qpf } else { 5 }
        }
        else { $config.QuestionsPerFile = 5 }

        Write-Step "Tuning: Rafiki=$($config.QuestionsPerEntry)/entry, Abu=$($config.QuestionsPerGap)/gap, Mojo=$($config.QuestionsPerFile)/file, Batch=$($config.BatchSize)" "OK"
    }

    # ═══════════════════════════════════════════
    # GROUP 4b: AI AGENT TARGETS
    # ═══════════════════════════════════════════
    $knownAgents = @('copilot', 'cursor', 'claude', 'coderabbit', 'aider', 'windsurf')
    if ($TargetAgents -and $TargetAgents.Count -gt 0) {
        $config['TargetAgents'] = $TargetAgents
    }
    elseif (-not $NonInteractive) {
        Write-Host ""
        Write-Host "  🤖 Which AI agents does your team use? (for health scoring)" -ForegroundColor Cyan
        Write-Host "    Available: $($knownAgents -join ', ')" -ForegroundColor DarkGray
        Write-Host "    Enter comma-separated list, or press Enter for all" -ForegroundColor DarkGray
        $agentInput = Read-Host "     Agents"
        if ([string]::IsNullOrWhiteSpace($agentInput)) {
            $config['TargetAgents'] = $knownAgents
        } else {
            $config['TargetAgents'] = @($agentInput -split ',' | ForEach-Object { $_.Trim().ToLower() } | Where-Object { $_ })
        }
    }
    else {
        $config['TargetAgents'] = $knownAgents  # Default: all
    }
    Write-Step "AI targets: $($config['TargetAgents'] -join ', ')" "OK"

    # ═══════════════════════════════════════════
    # GROUP 5: CURIOUS GEORGE SETUP
    # (mirrors the 7 setup questions from the prompt)
    # ═══════════════════════════════════════════
    if ('curious-george' -in $config.SelectedMonkeys) {
        Write-Host ""
        Write-Host "  🐵 Curious George — Setup Questions:" -ForegroundColor Yellow
        Write-Host "  (These pre-fill George's autonomous session)" -ForegroundColor DarkGray

        # CG-Q1: Questions per domain
        # Default: 10x the per-entry question count (George digs deeper)
        $georgeDefault = [Math]::Max(10, ($config.QuestionsPerEntry ?? 3) * 10)
        if ($GeorgeQuestionsPerDomain -gt 0) {
            $config.GeorgeQuestionsPerDomain = $GeorgeQuestionsPerDomain
        }
        elseif (-not $NonInteractive) {
            $gq = Read-Host "    1. Questions per domain? (default: $georgeDefault — 10x per-entry count)"
            $config.GeorgeQuestionsPerDomain = if ($gq -match '^\d+$') { [int]$gq } else { $georgeDefault }
        }
        else { $config.GeorgeQuestionsPerDomain = $georgeDefault }

        # CG-Q2: Focus area
        if ($PSBoundParameters.ContainsKey('GeorgeFocusArea')) {
            $config.GeorgeFocusArea = $GeorgeFocusArea
        }
        elseif (-not $NonInteractive) {
            $gf = Read-Host "    2. Focus area? (blank = all domains)"
            $config.GeorgeFocusArea = if ([string]::IsNullOrWhiteSpace($gf)) { '' } else { $gf }
        }
        else { $config.GeorgeFocusArea = '' }

        # CG-Q3: Difficulty
        if ($GeorgeDifficulty) {
            $config.GeorgeDifficulty = $GeorgeDifficulty
        }
        elseif (-not $NonInteractive) {
            Write-Host "    3. Difficulty:" -ForegroundColor DarkGray
            Write-Host "       [1] basic  [2] intermediate  [3] deep" -ForegroundColor DarkGray
            $gd = Read-Host "       Choose (default: deep)"
            $config.GeorgeDifficulty = switch ($gd) {
                '1' { 'basic' }
                '2' { 'intermediate' }
                default { 'deep' }
            }
        }
        else { $config.GeorgeDifficulty = 'deep' }

        # CG-Q4: Max consecutive covered before skip
        if ($GeorgeMaxSkip -gt 0) {
            $config.GeorgeMaxSkip = $GeorgeMaxSkip
        }
        elseif (-not $NonInteractive) {
            $gs = Read-Host "    4. Max consecutive covered before skipping domain? (default: 3)"
            $config.GeorgeMaxSkip = if ($gs -match '^\d+$') { [int]$gs } else { 3 }
        }
        else { $config.GeorgeMaxSkip = 3 }

        # CG-Q5: Auto-fix mode
        if ($GeorgeFixMode) {
            $config.GeorgeFixMode = $GeorgeFixMode
        }
        elseif (-not $NonInteractive) {
            Write-Host "    5. Auto-fix gaps?" -ForegroundColor DarkGray
            Write-Host "       [1] yes (edit docs)  [2] dry-run (report only)" -ForegroundColor DarkGray
            $gfm = Read-Host "       Choose (default: yes)"
            $config.GeorgeFixMode = if ($gfm -eq '2') { 'dry-run' } else { 'yes' }
        }
        else { $config.GeorgeFixMode = 'yes' }

        # CG-Q6: Discovery mode
        if ($GeorgeDiscoveryMode) {
            $config.GeorgeDiscoveryMode = $GeorgeDiscoveryMode
        }
        elseif (-not $NonInteractive) {
            Write-Host "    6. Discovery mode?" -ForegroundColor DarkGray
            Write-Host "       [1] full (find & create new docs)  [2] audit-only (existing docs)" -ForegroundColor DarkGray
            $gdm = Read-Host "       Choose (default: full)"
            $config.GeorgeDiscoveryMode = if ($gdm -eq '2') { 'audit-only' } else { 'full' }
        }
        else { $config.GeorgeDiscoveryMode = 'full' }

        Write-Step "George: $($config.GeorgeQuestionsPerDomain)q/domain, $($config.GeorgeDifficulty), fix=$($config.GeorgeFixMode), discovery=$($config.GeorgeDiscoveryMode)" "OK"
    }

    # ═══════════════════════════════════════════
    # SUMMARY
    # ═══════════════════════════════════════════
    Write-Host ""
    Write-Host "  ╔══════════════════════════════════════════╗" -ForegroundColor Green
    Write-Host "  ║  ✅ Mission briefing complete!            ║" -ForegroundColor Green
    Write-Host "  ╚══════════════════════════════════════════╝" -ForegroundColor Green

    # Build ordered monkey list (sorted by phase)
    $orderedMonkeys = @()
    foreach ($m in $script:AllMonkeys) {
        if ($m.Id -in $config.SelectedMonkeys) {
            $orderedMonkeys += $m
        }
    }
    $config.OrderedMonkeys = $orderedMonkeys

    Write-Host ""
    Write-Host "  Execution order:" -ForegroundColor Cyan
    foreach ($m in $orderedMonkeys) {
        Write-Host "    Phase $($m.Phase): $($m.Emoji) $($m.Name) [$($m.Mode)]" -ForegroundColor DarkGray
    }
    Write-Host ""

    if (-not $NonInteractive) {
        $confirm = Read-Host "  🚀 Ready to deploy the army? [Y/n]"
        if ($confirm -match '^[Nn]') {
            throw "Mission aborted by user."
        }
    }

    return $config
}

function Get-MonkeyById {
    <#
    .SYNOPSIS
        Looks up monkey metadata by ID.
    #>
    param([Parameter(Mandatory)][string]$Id)
    return $script:AllMonkeys | Where-Object { $_.Id -eq $Id }
}

function Get-MonkeyPacks {
    <# Returns the pack definitions. #>
    return $script:MonkeyPacks
}

# Export all public functions
Export-ModuleMember -Function @(
    'Write-MonkeyBanner'
    'Write-Phase'
    'Write-Step'
    'Write-MonkeySummary'
    'Invoke-CopilotWithRetry'
    'Invoke-CopilotBatch'
    'Invoke-SingleQuestion'
    'Get-QuestionId'
    'Get-BatchCheckpoint'
    'Save-BatchCheckpoint'
    'Get-IncrementalState'
    'Save-IncrementalState'
    'Get-ChangedFiles'
    'Select-IncrementalEntryPoints'
    'Get-DocReferences'
    'Invoke-MonkeySetup'
    'Test-Preflight'
    'Test-CopilotInRepo'
    'Select-MonkeyModel'
    'Invoke-MonkeyCommit'
    'Invoke-MonkeyQuestions'
    'Save-MonkeyReport'
    'New-MonkeyResult'
    'Start-AgentMonkey'
    'Read-AgentStatus'
    'Get-ArmyConfig'
    'Get-MonkeyById'
    'Get-MonkeyPacks'
)

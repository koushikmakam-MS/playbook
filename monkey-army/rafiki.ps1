<#
.SYNOPSIS
    Rafiki 🐒 — The Wise Code Reader (Monkey Army)

.DESCRIPTION
    Rafiki discovers code entry points (controllers, handlers, routes), generates intelligent
    questions about them using a hybrid regex+copilot approach, feeds those questions to
    GitHub Copilot CLI to trigger documentation self-healing, and tracks results.

    Part of the Monkey Army 🐒🐵 framework.

.PARAMETER RepoUrl
    Git repo URL to clone.

.PARAMETER ClonePath
    Local path for clone. Defaults to .\monkey-workspace

.PARAMETER RepoPath
    Path to an already-cloned local repo. Skips clone.

.PARAMETER QuestionsPerEntry
    Number of random questions per entry point (default 10). Complexity-weighted.

.PARAMETER EntryPointGlob
    Override glob patterns for entry point discovery. Auto-detects if not specified.

.PARAMETER BranchName
    Working branch name. Defaults to rafiki/<timestamp>.

.PARAMETER BaseBranch
    Branch to pull latest from. If not provided, prompts the user.

.PARAMETER DryRun
    Stage changes only, don't commit.

.PARAMETER Commit
    Auto-commit doc changes to the branch.

.PARAMETER Model
    Copilot model to use. If not specified, auto-probes best available.

.PARAMETER OutputDir
    Directory for session transcripts. Defaults to .rafiki-output/

.PARAMETER MaxRetries
    Max retries per copilot call on capacity/transient errors. Default 3.

.PARAMETER RetryBaseDelay
    Base delay in seconds for exponential backoff. Default 30.

.PARAMETER CallTimeout
    Hard timeout in seconds per copilot -p call. Default 300 (5 min).

.PARAMETER UseBaseBranch
    Work directly on the base branch instead of creating a new one.

.PARAMETER ExcludePattern
    Glob patterns to exclude from entry point discovery.

.PARAMETER ShowVerbose
    Show copilot output in real-time.

.EXAMPLE
    .\rafiki.ps1 -RepoUrl "https://github.com/org/repo.git" -ClonePath "C:\workspace" -Commit

.EXAMPLE
    .\rafiki.ps1 -RepoPath "C:\myrepo" -DryRun -QuestionsPerEntry 5 -Model "claude-sonnet-4"
#>

[CmdletBinding(DefaultParameterSetName = 'Clone')]
param(
    [Parameter(ParameterSetName = 'Clone')]
    [string]$RepoUrl,

    [Parameter(ParameterSetName = 'Clone')]
    [string]$ClonePath = ".\monkey-workspace",

    [Parameter(ParameterSetName = 'Local', Mandatory)]
    [string]$RepoPath,

    [int]$QuestionsPerEntry = 10,

    [string[]]$EntryPointGlob,

    [string]$BranchName,

    [string]$BaseBranch,

    [switch]$UseBaseBranch,

    [switch]$DryRun,

    [switch]$Commit,

    [string]$Model,

    [string]$OutputDir = ".rafiki-output",

    [int]$MaxRetries = 3,

    [int]$RetryBaseDelay = 30,

    [int]$CallTimeout = 300,

    [string[]]$ExcludePattern = @(),

    [int]$BatchSize = 5,
    [int]$MaxQuestions = 0,

    [switch]$Incremental,

    [string]$Since,

    [switch]$ShowVerbose,

    # Internal mode (called by orchestrator — skips setup/commit)
    [switch]$Internal,
    [string]$InternalRepoPath,
    [string]$InternalModel,
    [string]$InternalOutputPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# Import shared module
$sharedModule = Join-Path $PSScriptRoot "..\shared\MonkeyCommon.psm1"
if (-not (Test-Path $sharedModule)) {
    throw "Shared module not found at $sharedModule. Ensure monkey-army/shared/ exists."
}
Import-Module $sharedModule -Force

# ─────────────────────────────────────────────
# Region: Constants
# ─────────────────────────────────────────────

$script:MONKEY_NAME = "Rafiki"
$script:MONKEY_EMOJI = "🐒"
$script:MONKEY_VERSION = "1.0.0"
$script:MONKEY_TAGLINE = "The Wise Code Reader"

$script:QUESTION_CATEGORIES = @(
    "Data Flow"
    "Error Handling"
    "Telemetry & Logging"
    "Config Dependencies"
    "Input Validation"
    "Security & Auth"
    "Testing & Coverage"
    "Architecture & Layers"
    "External Dependencies"
    "State Management"
    "Performance"
    "Documentation"
)

# Language-aware entry point glob patterns
$script:LANGUAGE_PATTERNS = @{
    "csharp" = @{
        Globs = @(
            "**/*Controller*.cs"
            "**/*Hub*.cs"
            "**/*Endpoint*.cs"
            "**/*Handler*.cs"
        )
        RouteIndicators = @(
            '\[Route\('
            '\[Http(Get|Post|Put|Delete|Patch)\('
            '\[ApiController\]'
            'ControllerBase'
            'Controller\b'
            'MapGet|MapPost|MapPut|MapDelete'
            '\[SignalR'
        )
        MethodRegex = '(?m)^\s*public\s+(?:async\s+)?(?:Task<[^>]+>|Task|IActionResult|ActionResult[^)]*|[A-Za-z<>\[\]]+)\s+(\w+)\s*\('
    }
    "python" = @{
        Globs = @(
            "**/views.py"
            "**/routes.py"
            "**/*controller*.py"
            "**/*router*.py"
            "**/*endpoint*.py"
            "**/app.py"
            "**/main.py"
        )
        RouteIndicators = @(
            '@app\.(get|post|put|delete|route|patch)'
            '@router\.'
            'def\s+\w+.*request'
            'APIRouter'
            'Blueprint'
            'urlpatterns'
        )
        MethodRegex = '(?m)^(?:async\s+)?def\s+(\w+)\s*\('
    }
    "javascript" = @{
        Globs = @(
            "**/*controller*.js"
            "**/*controller*.ts"
            "**/routes/*.js"
            "**/routes/*.ts"
            "**/*Router*.js"
            "**/*Router*.ts"
            "**/*handler*.js"
            "**/*handler*.ts"
            "**/*middleware*.js"
            "**/*middleware*.ts"
        )
        RouteIndicators = @(
            'router\.(get|post|put|delete|patch|use)'
            'app\.(get|post|put|delete|patch|use)'
            '@(Get|Post|Put|Delete|Patch)\('
            'express\(\)'
            'createRouter'
            'export\s+(default\s+)?function'
        )
        MethodRegex = '(?m)(?:export\s+)?(?:async\s+)?(?:function\s+(\w+)|(\w+)\s*[=:]\s*(?:async\s+)?(?:function|\([^)]*\)\s*=>))'
    }
    "java" = @{
        Globs = @(
            "**/*Controller*.java"
            "**/*Resource*.java"
            "**/*Endpoint*.java"
            "**/*Handler*.java"
        )
        RouteIndicators = @(
            '@(Get|Post|Put|Delete|Patch|Request)Mapping'
            '@Path\('
            '@RestController'
            '@Controller'
            'HttpServlet'
        )
        MethodRegex = '(?m)^\s*(?:public|protected)\s+(?:\w+\s+)*(\w+)\s*\('
    }
    "go" = @{
        Globs = @(
            "**/*handler*.go"
            "**/*controller*.go"
            "**/*server*.go"
            "**/*router*.go"
        )
        RouteIndicators = @(
            'func\s+\w+.*http\.ResponseWriter'
            'http\.Handle'
            'mux\.(Handle|Get|Post|Put|Delete)'
            'gin\.(Context|Engine)'
            'echo\.(GET|POST|PUT|DELETE)'
            'chi\.(Get|Post|Put|Delete)'
        )
        MethodRegex = '(?m)^func\s+(?:\([^)]+\)\s+)?(\w+)\s*\('
    }
    "ruby" = @{
        Globs = @(
            "**/*controller*.rb"
            "**/routes.rb"
            "**/routes/*.rb"
            "**/*handler*.rb"
        )
        RouteIndicators = @(
            'class\s+\w+Controller'
            'def\s+(index|show|create|update|destroy|new|edit)\b'
            'resources?\s+:'
            'get\s+[''"]/'
            'post\s+[''"]/'
            'Rails\.application\.routes'
            'Sinatra'
        )
        MethodRegex = '(?m)^\s*def\s+(\w+)'
    }
    "php" = @{
        Globs = @(
            "**/*Controller*.php"
            "**/*Handler*.php"
            "**/routes/*.php"
            "**/routes.php"
        )
        RouteIndicators = @(
            '#\[Route\('
            'class\s+\w+Controller'
            'Route::(get|post|put|delete|patch)'
            '@(Get|Post|Put|Delete)Mapping'
            'function\s+(index|show|store|update|destroy)\b'
        )
        MethodRegex = '(?m)^\s*(?:public|protected|private)?\s*function\s+(\w+)\s*\('
    }
    "kotlin" = @{
        Globs = @(
            "**/*Controller*.kt"
            "**/*Resource*.kt"
            "**/*Handler*.kt"
            "**/*Endpoint*.kt"
        )
        RouteIndicators = @(
            '@(Get|Post|Put|Delete|Patch|Request)Mapping'
            '@RestController'
            '@Controller'
            '@Path\('
        )
        MethodRegex = '(?m)^\s*(?:fun|suspend\s+fun)\s+(\w+)\s*\('
    }
    "rust" = @{
        Globs = @(
            "**/*handler*.rs"
            "**/*controller*.rs"
            "**/*routes*.rs"
            "**/*api*.rs"
        )
        RouteIndicators = @(
            '#\[(?:get|post|put|delete|patch)\('
            'web::(get|post|put|delete|resource)'
            'HttpResponse'
            'actix_web|axum|rocket|warp'
            'async\s+fn\s+\w+.*(?:Request|State|Json)'
        )
        MethodRegex = '(?m)^\s*(?:pub\s+)?(?:async\s+)?fn\s+(\w+)\s*[<(]'
    }
    "grpc_graphql" = @{
        Globs = @(
            "**/*.proto"
            "**/*resolver*.js"
            "**/*resolver*.ts"
            "**/*resolver*.py"
            "**/*resolver*.go"
            "**/*resolver*.rb"
        )
        RouteIndicators = @(
            'service\s+\w+'
            'rpc\s+\w+'
            '@(Query|Mutation|Resolver|Subscription)\('
            'type\s+Query'
            'type\s+Mutation'
        )
        MethodRegex = '(?m)(?:rpc|def|func|export\s+(?:async\s+)?function)\s+(\w+)\s*\('
    }
}

# ─────────────────────────────────────────────
# Region: Phase 2 — Discovery
# ─────────────────────────────────────────────

function Get-EntryPoints {
    param([string]$RootDir)

    Write-Phase "PHASE 2" "Discovery — Finding Entry Points"

    $allEntryPoints = @()

    if ($EntryPointGlob) {
        foreach ($glob in $EntryPointGlob) {
            $files = Get-ChildItem -Path $RootDir -Recurse -Filter $glob -File -ErrorAction SilentlyContinue
            foreach ($f in $files) {
                $allEntryPoints += @{
                    Path       = $f.FullName
                    RelPath    = $f.FullName.Substring($RootDir.Length + 1)
                    Language   = "custom"
                    Confidence = 1.0
                }
            }
        }
        Write-Step "Found $($allEntryPoints.Count) files from custom globs" "OK"
    }
    else {
        foreach ($lang in $script:LANGUAGE_PATTERNS.Keys) {
            $langConfig = $script:LANGUAGE_PATTERNS[$lang]
            foreach ($glob in $langConfig.Globs) {
                $parts = $glob -split '/'
                $filter = $parts[-1]
                $files = Get-ChildItem -Path $RootDir -Recurse -Filter $filter -File -ErrorAction SilentlyContinue

                foreach ($exclude in $ExcludePattern) {
                    $files = $files | Where-Object { $_.FullName -notlike $exclude }
                }

                $files = $files | Where-Object {
                    $_.FullName -notmatch '[\\/](bin|obj|node_modules|vendor|\.git|dist|build|test|tests|__pycache__|target|\.gradle|\.rafiki-output|\.abu-output|\.monkey-output|\.mojo-jojo-output)[\\/]'
                }

                foreach ($f in $files) {
                    $content = Get-Content $f.FullName -Raw -ErrorAction SilentlyContinue
                    if (-not $content) { continue }

                    $confidence = 0.3
                    $matchCount = 0
                    foreach ($indicator in $langConfig.RouteIndicators) {
                        if ($content -match $indicator) { $matchCount++ }
                    }

                    if ($matchCount -ge 3) { $confidence = 1.0 }
                    elseif ($matchCount -ge 2) { $confidence = 0.8 }
                    elseif ($matchCount -ge 1) { $confidence = 0.6 }

                    $relPath = $f.FullName.Substring($RootDir.Length + 1)
                    if ($allEntryPoints | Where-Object { $_.Path -eq $f.FullName }) { continue }

                    $allEntryPoints += @{
                        Path       = $f.FullName
                        RelPath    = $relPath
                        Language   = $lang
                        Confidence = $confidence
                    }
                }
            }
        }
    }

    $allEntryPoints = $allEntryPoints | Sort-Object { $_.Confidence } -Descending
    $confirmed = @($allEntryPoints | Where-Object { $_.Confidence -ge 0.6 }).Count
    $possible  = @($allEntryPoints | Where-Object { $_.Confidence -lt 0.6 }).Count
    Write-Step "Discovered: $confirmed confirmed + $possible possible entry points" "OK"

    if ($allEntryPoints.Count -eq 0) {
        Write-Step "No entry points found! Use -EntryPointGlob to specify patterns." "ERROR"
        throw "No entry points discovered."
    }

    # Display table
    Write-Host ""
    Write-Host "  ┌─────────────────────────────────────────────────────────┬──────────┬────────────┐" -ForegroundColor DarkGray
    Write-Host "  │ Entry Point                                             │ Language │ Confidence │" -ForegroundColor DarkGray
    Write-Host "  ├─────────────────────────────────────────────────────────┼──────────┼────────────┤" -ForegroundColor DarkGray
    foreach ($ep in $allEntryPoints | Select-Object -First 30) {
        $name = $ep.RelPath
        if ($name.Length -gt 55) { $name = "..." + $name.Substring($name.Length - 52) }
        $confStr = "{0:P0}" -f $ep.Confidence
        $confColor = if ($ep.Confidence -ge 0.6) { "Green" } elseif ($ep.Confidence -ge 0.4) { "Yellow" } else { "Red" }
        Write-Host ("  │ {0,-55} │ {1,-8} │ " -f $name, $ep.Language) -ForegroundColor DarkGray -NoNewline
        Write-Host ("{0,-10}" -f $confStr) -ForegroundColor $confColor -NoNewline
        Write-Host " │" -ForegroundColor DarkGray
    }
    if ($allEntryPoints.Count -gt 30) {
        Write-Host "  │ ... and $($allEntryPoints.Count - 30) more                                         │          │            │" -ForegroundColor DarkGray
    }
    Write-Host "  └─────────────────────────────────────────────────────────┴──────────┴────────────┘" -ForegroundColor DarkGray

    return $allEntryPoints
}

# ─────────────────────────────────────────────
# Region: Phase 3 — Question Generation
# ─────────────────────────────────────────────

function Get-MethodsFromFile {
    param([string]$FilePath, [string]$Language)

    $content = Get-Content $FilePath -Raw -ErrorAction SilentlyContinue
    if (-not $content) { return @() }

    $langConfig = $script:LANGUAGE_PATTERNS[$Language]
    if (-not $langConfig -or -not $langConfig.MethodRegex) {
        return @([System.IO.Path]::GetFileNameWithoutExtension($FilePath))
    }

    $methods = @()
    $matches_ = [regex]::Matches($content, $langConfig.MethodRegex)
    foreach ($m in $matches_) {
        $name = if ($m.Groups[1].Success) { $m.Groups[1].Value } elseif ($m.Groups[2].Success) { $m.Groups[2].Value } else { $null }
        if ($name -and $name -notin $methods -and $name -notmatch '^(if|else|for|while|switch|catch|try|using|get|set|var|let|const)$') {
            $methods += $name
        }
    }
    return $methods
}

function New-Questions {
    param(
        [array]$EntryPoints,
        [string]$WorkingDirectory
    )

    Write-Phase "PHASE 3" "Question Generation — Hybrid (regex + copilot)"

    $methodCounts = @()
    foreach ($ep in $EntryPoints) {
        $methods = @(Get-MethodsFromFile -FilePath $ep.Path -Language $ep.Language)
        $ep.Methods = $methods
        $ep.MethodCount = $methods.Count
        $methodCounts += [Math]::Max($methods.Count, 1)
    }
    $medianMethodCount = ($methodCounts | Sort-Object)[[Math]::Floor($methodCounts.Count / 2)]
    if ($medianMethodCount -eq 0) { $medianMethodCount = 1 }

    $allQuestions = @()
    $questionHashes = @{}
    $totalEntryPoints = $EntryPoints.Count
    $currentEp = 0

    foreach ($ep in $EntryPoints) {
        $currentEp++
        $pct = [Math]::Round(($currentEp / $totalEntryPoints) * 100)
        Write-Progress -Activity "Generating questions" -Status "$currentEp/$totalEntryPoints — $($ep.RelPath)" -PercentComplete $pct

        $ratio = $ep.MethodCount / $medianMethodCount
        $adjustedCount = [Math]::Round($QuestionsPerEntry * $ratio)
        $adjustedCount = [Math]::Max(3, [Math]::Min($QuestionsPerEntry * 2, $adjustedCount))

        $categoryList = ($script:QUESTION_CATEGORIES | ForEach-Object { "- $_" }) -join "`n"
        $methodList = if ($ep.Methods.Count -gt 0) {
            "Methods found: " + ($ep.Methods -join ", ")
        } else {
            "No specific methods extracted — analyze the entire file."
        }

        $genPrompt = @"
Read the file at path: $($ep.RelPath)

$methodList

Generate exactly $adjustedCount questions about this code. The questions should be answerable by reading the codebase.

RULES:
1. You MUST generate exactly 1 question from EACH of these categories before any repeats:
$categoryList
2. After covering each category once, fill remaining slots from random categories.
3. Do NOT cluster questions around one concern.
4. Questions must be specific to the actual code in this file — reference real method names, classes, patterns.
5. Output ONLY a JSON array of strings. No explanation, no markdown fences, no preamble.

Example output format:
["Question 1 text here?", "Question 2 text here?", "Question 3 text here?"]
"@

        Write-Step "[$currentEp/$totalEntryPoints] Generating $adjustedCount questions for $($ep.RelPath)..." "INFO"

        $result = Invoke-CopilotWithRetry -Prompt $genPrompt -ModelName $script:SelectedModel -WorkingDirectory $WorkingDirectory -Retries $MaxRetries -BaseDelay $RetryBaseDelay -Timeout $CallTimeout

        if (-not $result.Success) {
            Write-Step "Failed to generate questions for $($ep.RelPath): $($result.Error)" "ERROR"
            continue
        }

        $questions = @()
        try {
            $output = $result.Output.Trim()
            if ($output -match '\[[\s\S]*\]') {
                $jsonMatch = $Matches[0]
                $questions = @($jsonMatch | ConvertFrom-Json)
            }
        }
        catch {
            Write-Step "Failed to parse questions JSON for $($ep.RelPath). Falling back to line parsing." "WARN"
            $questions = @()
            $lines = $result.Output -split "`n"
            foreach ($line in $lines) {
                if ($line -match '^\s*\d+[\.\)]\s*(.+)') {
                    $questions += $Matches[1].Trim()
                }
            }
        }

        if ($questions.Count -eq 0) {
            Write-Step "No questions parsed for $($ep.RelPath)" "WARN"
            continue
        }

        foreach ($q in $questions) {
            $hash = [System.BitConverter]::ToString(
                [System.Security.Cryptography.SHA256]::Create().ComputeHash(
                    [System.Text.Encoding]::UTF8.GetBytes($q.ToLower().Trim())
                )
            ).Substring(0, 16)

            if (-not $questionHashes.ContainsKey($hash)) {
                $questionHashes[$hash] = $true
                $allQuestions += @{
                    EntryPoint = $ep.RelPath
                    Language   = $ep.Language
                    Question   = $q
                    Category   = "auto"
                }
            }
        }

        Write-Step "Generated $($questions.Count) unique questions ($($allQuestions.Count) total)" "OK"
    }

    Write-Progress -Activity "Generating questions" -Completed

    $allQuestions = $allQuestions | Sort-Object { Get-Random }
    $questionsPath = Join-Path $script:OutputPath "questions.json"
    $allQuestions | ConvertTo-Json -Depth 5 | Set-Content $questionsPath -Encoding UTF8
    Write-Step "Saved $($allQuestions.Count) questions to questions.json" "OK"

    return $allQuestions
}

# ─────────────────────────────────────────────
# Region: Main Orchestrator
# ─────────────────────────────────────────────

function Start-Rafiki {
    $startTime = Get-Date

    try {
        # ── Mode split: standalone vs internal ──
        if (-not $Internal) {
            Write-MonkeyBanner -Name $script:MONKEY_NAME -Emoji $script:MONKEY_EMOJI -Version $script:MONKEY_VERSION -Tagline $script:MONKEY_TAGLINE
            Test-Preflight
            $setup = Invoke-MonkeySetup -RepoUrl $RepoUrl -ClonePath $ClonePath -RepoPath $RepoPath `
                -BaseBranch $BaseBranch -UseBaseBranch:$UseBaseBranch -BranchName $BranchName `
                -BranchPrefix "rafiki" -OutputDirName $OutputDir
            $workDir = $setup.WorkDir
            $script:BranchName = $setup.Branch
            $script:OutputPath = $setup.OutputPath
            $script:SelectedModel = Select-MonkeyModel -UserModel $Model -WorkingDirectory $workDir
            Test-CopilotInRepo -WorkingDirectory $workDir
        }
        else {
            Write-Phase "RAFIKI" "Running in internal mode (orchestrated)"
            $workDir = $InternalRepoPath
            $script:SelectedModel = $InternalModel
            $script:OutputPath = $InternalOutputPath
            $script:BranchName = ''
            if (-not (Test-Path $script:OutputPath)) { New-Item -ItemType Directory -Path $script:OutputPath -Force | Out-Null }
            New-Item -ItemType Directory -Path (Join-Path $script:OutputPath "session-logs") -Force | Out-Null
        }

        # Phase 2: Discovery
        $entryPoints = Get-EntryPoints -RootDir $workDir

        # Incremental filter — only process changed files
        if ($Incremental -or $Since) {
            $sinceRef = $Since
            if (-not $sinceRef) {
                $lastState = Get-IncrementalState -WorkingDirectory $workDir
                if ($lastState) {
                    $sinceRef = $lastState.CommitHash
                    Write-Step "Incremental: using last run commit $sinceRef" "INFO"
                }
                else {
                    Write-Step "No prior run found — running full (use -Since to specify a ref)" "WARN"
                }
            }
            if ($sinceRef) {
                $changedFiles = Get-ChangedFiles -WorkingDirectory $workDir -Since $sinceRef
                $entryPoints = Select-IncrementalEntryPoints -EntryPoints $entryPoints -ChangedFiles $changedFiles -WorkingDirectory $workDir
                if ($entryPoints.Count -eq 0) {
                    Write-Step "No entry points changed since '$sinceRef' — nothing to do" "OK"
                    $currentCommit = (& git -C $workDir rev-parse HEAD 2>&1).Trim()
                    Save-IncrementalState -WorkingDirectory $workDir -MonkeyName "rafiki" -CommitHash $currentCommit -EntryPointCount 0 -QuestionsAsked 0
                    return New-MonkeyResult -MonkeyName "Rafiki" -ExitStatus 'SKIPPED' -Model $script:SelectedModel
                }
            }
        }

        # Phase 3: Question generation
        $questions = New-Questions -EntryPoints $entryPoints -WorkingDirectory $workDir

        # Phase 4: Execution (shared)
        $execStats = Invoke-MonkeyQuestions -Questions $questions -WorkingDirectory $workDir `
            -OutputPath $script:OutputPath -ModelName $script:SelectedModel -MonkeyEmoji $script:MONKEY_EMOJI `
            -MaxRetries $MaxRetries -RetryBaseDelay $RetryBaseDelay -CallTimeout $CallTimeout -BatchSize $BatchSize -MaxQuestions $MaxQuestions -ShowVerbose:$ShowVerbose

        # Phase 5: Commit/Stage (standalone only)
        $filesChanged = 0
        if (-not $Internal) {
            $filesChanged = Invoke-MonkeyCommit -WorkingDirectory $workDir -OutputDirName $OutputDir `
                -MonkeyName $script:MONKEY_NAME -MonkeyEmoji $script:MONKEY_EMOJI -BranchName $script:BranchName `
                -ModelName $script:SelectedModel -QuestionsAnswered $execStats.Answered -DryRun:$DryRun -Commit:$Commit
        }

        # Summary + Report
        $duration = (Get-Date) - $startTime
        $reportStats = Save-MonkeyReport -ExecStats $execStats -OutputPath $script:OutputPath -MonkeyName $script:MONKEY_NAME

        # Save incremental state for next run
        $currentCommit = (& git -C $workDir rev-parse HEAD 2>&1).Trim()
        Save-IncrementalState -WorkingDirectory $workDir -MonkeyName "rafiki" -CommitHash $currentCommit -EntryPointCount $entryPoints.Count -QuestionsAsked $questions.Count

        $runStats = @{
            "01_EntryPoints"        = $entryPoints.Count
            "02_QuestionsGenerated" = $questions.Count
            "03_QuestionsAnswered"  = $execStats.Answered
            "04_QuestionsFailed"    = $execStats.Failed
            "05_TotalRetries"       = $execStats.Retries
            "06_FilesChanged"       = $filesChanged
            "07_DocGrounded"        = $execStats.DocGroundedCount
            "08_ModelUsed"          = if ($script:SelectedModel) { $script:SelectedModel } else { "(default)" }
            "09_Branch"             = $script:BranchName
            "10_Duration"           = "{0:hh\:mm\:ss}" -f $duration
        }
        $runStats | ConvertTo-Json -Depth 3 | Set-Content (Join-Path $script:OutputPath "summary.json") -Encoding UTF8
        Write-MonkeySummary -Stats $runStats -Emoji $script:MONKEY_EMOJI
        Write-Host "  $($script:MONKEY_EMOJI) Rafiki complete!" -ForegroundColor Green

        # Return standardized result
        return New-MonkeyResult -MonkeyName $script:MONKEY_NAME -Duration $duration `
            -Model $script:SelectedModel -ExitStatus 'SUCCESS' `
            -QuestionsAsked $questions.Count -QuestionsAnswered $execStats.Answered `
            -DocRefsFound $execStats.DocGroundedCount -FilesModified $filesChanged `
            -DocsGroundedPct $reportStats.DocGroundedPct -RetryCount $execStats.Retries
    }
    catch {
        $duration = (Get-Date) - $startTime
        Write-Host "`n  ❌ FATAL: $($_.Exception.Message)" -ForegroundColor Red
        Write-Host "  Stack: $($_.ScriptStackTrace)" -ForegroundColor DarkRed
        if ($Internal) {
            return New-MonkeyResult -MonkeyName $script:MONKEY_NAME -Duration $duration `
                -Model $script:SelectedModel -ExitStatus 'FAILED' -Errors @($_.Exception.Message)
        }
        exit 1
    }
}

Start-Rafiki

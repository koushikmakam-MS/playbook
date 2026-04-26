<#
.SYNOPSIS
    King Louie 👑 — The API Contract Validator (Monkey Army)

.DESCRIPTION
    King Louie discovers API specification files (OpenAPI/Swagger) and actual API endpoints
    in code, cross-references them to find contract gaps, generates targeted questions about
    those gaps, feeds them to GitHub Copilot CLI, and tracks results.

    Phase 1: Setup (shared — clone/branch/model/preflight)
    Phase 2: Discovery — Find spec files + code endpoints, cross-reference
    Phase 3: Question Generation — Copilot generates questions about contract gaps
    Phase 4: Question Execution (shared — copilot CLI with retry)
    Phase 5: Commit & Report (shared — git stage/commit + healing report)

    Part of the Monkey Army 🐒🐵 framework. Phase 4 in the army.

.PARAMETER RepoUrl
    Git repo URL to clone.
.PARAMETER ClonePath
    Local path for clone. Defaults to .\monkey-workspace
.PARAMETER RepoPath
    Path to an already-cloned local repo. Skips clone.
.PARAMETER BaseBranch
    Branch to pull latest from. If not provided, prompts the user.
.PARAMETER UseBaseBranch
    Work directly on the base branch instead of creating a new one.
.PARAMETER BranchName
    Working branch name. Defaults to king-louie/<timestamp>.
.PARAMETER Model
    Copilot model to use. If not specified, auto-probes best available.
.PARAMETER QuestionsPerEndpoint
    Number of questions per endpoint gap. Default: 3.
.PARAMETER DryRun
    Stage changes only, don't commit.
.PARAMETER Commit
    Auto-commit doc changes to the branch.
.PARAMETER MaxRetries
    Max retries per copilot call. Default: 3.
.PARAMETER RetryBaseDelay
    Base delay in seconds for exponential backoff. Default: 30.
.PARAMETER CallTimeout
    Timeout per copilot call (seconds). Default: 300.
.PARAMETER ShowVerbose
    Show copilot output in real-time.

.EXAMPLE
    .\king-louie.ps1 -RepoPath "C:\myrepo" -DryRun -QuestionsPerEndpoint 3

.EXAMPLE
    .\king-louie.ps1 -RepoUrl "https://github.com/org/repo.git" -Commit -Model "claude-sonnet-4"
#>

[CmdletBinding()]
param(
    [string]$RepoUrl,
    [string]$ClonePath = ".\monkey-workspace",
    [string]$RepoPath,
    [string]$BaseBranch,
    [switch]$UseBaseBranch,
    [string]$BranchName,
    [string]$Model,
    [int]$QuestionsPerEndpoint = 3,
    [switch]$DryRun,
    [switch]$Commit,
    [int]$MaxRetries = 3,
    [int]$RetryBaseDelay = 30,
    [int]$CallTimeout = 300,
    [int]$BatchSize = 5,
    [int]$GapBatchSize = 10,
    [int]$MaxQuestions = 0,

    [switch]$Incremental,

    [string]$Since,

    [switch]$ShowVerbose,

    # Parallel gen mode
    [switch]$GenOnly,
    [array]$PreGenQuestions = @(),

    # Internal mode (called by orchestrator — skips setup/commit)
    [switch]$Internal,
    [string]$InternalRepoPath,
    [string]$InternalModel,
    [string]$InternalOutputPath
)

$ErrorActionPreference = "Stop"

# ── Import shared module ─────────────────────────────────────────────
$sharedModule = Join-Path $PSScriptRoot "..\shared\MonkeyCommon.psm1"
if (-not (Test-Path $sharedModule)) {
    Write-Host "❌ Shared module not found at: $sharedModule" -ForegroundColor Red
    exit 1
}
Import-Module $sharedModule -Force

# ─────────────────────────────────────────────
# Region: Constants
# ─────────────────────────────────────────────

$script:MONKEY_NAME    = "King Louie"
$script:MONKEY_EMOJI   = "👑"
$script:MONKEY_VERSION = "1.0.0"
$script:MONKEY_TAGLINE = "The API Contract Validator"
$script:MONKEY_PREFIX  = "king-louie"
$script:OUTPUT_DIR     = ".monkey-output"

# Default excludes for file scanning
$script:DEFAULT_EXCLUDES = '([\\/](bin|obj|node_modules|vendor|\.git|dist|build|target|\.gradle|__pycache__|\.monkey-output|\.rafiki-output|\.abu-output|\.mojo-jojo-output)[\\/])'

# Route patterns by language — regex to extract HTTP method + path from code
$script:ROUTE_PATTERNS = @{
    '*.cs'   = @(
        '\[Http(Get|Post|Put|Delete|Patch)\s*\("([^"]+)"\)\]'
        '\[Route\("([^"]+)"\)\]'
    )
    '*.py'   = @(
        '@app\.(get|post|put|delete|patch)\s*\(\s*"([^"]+)"'
        '@router\.(get|post|put|delete|patch)\s*\(\s*"([^"]+)"'
    )
    '*.ts'   = @(
        '@(Get|Post|Put|Delete|Patch)\s*\([''`""]([^''`""]+)'
        'router\.(get|post|put|delete|patch)\s*\(\s*[''`""]([^''`""]+)'
    )
    '*.java' = @(
        '@(Get|Post|Put|Delete|Patch)Mapping\s*\(\s*"([^"]+)"'
        '@RequestMapping\s*\(\s*"([^"]+)"'
    )
    '*.go'   = @(
        'r\.(Get|Post|Put|Delete|Patch)\s*\(\s*"([^"]+)"'
        'HandleFunc\s*\(\s*"([^"]+)"'
    )
    '*.rb'   = @(
        '(get|post|put|delete|patch)\s+[''`""]([^''`""]+)'
    )
    '*.php'  = @(
        'Route::(get|post|put|delete)\s*\(\s*[''`""]([^''`""]+)'
    )
}

# ─────────────────────────────────────────────
# Region: Phase 2 — Discovery
# ─────────────────────────────────────────────

function Find-ApiSpecFiles {
    <#
    .SYNOPSIS
        Finds OpenAPI/Swagger spec files in the repo via git ls-files.
    #>
    param([string]$WorkDir)

    Write-Step "Scanning for API specification files..." "INFO"

    $specPatterns = @(
        '**/openapi*.json'
        '**/openapi*.yaml'
        '**/openapi*.yml'
        '**/swagger*.json'
        '**/swagger*.yaml'
        '**/swagger*.yml'
        '**/api-spec*'
    )

    $specFiles = @()
    Push-Location $WorkDir
    try {
        foreach ($pattern in $specPatterns) {
            $files = git ls-files $pattern 2>$null
            if ($files) {
                $specFiles += @($files -split "`n" | Where-Object { $_ -and $_ -notmatch $script:DEFAULT_EXCLUDES })
            }
        }
        $specFiles = @($specFiles | Sort-Object -Unique)
    }
    finally {
        Pop-Location
    }

    Write-Step "Found $($specFiles.Count) API spec files" $(if ($specFiles.Count -gt 0) { "OK" } else { "WARN" })
    foreach ($f in $specFiles | Select-Object -First 15) {
        Write-Host "    📄 $f" -ForegroundColor DarkGray
    }

    return $specFiles
}

function Find-CodeEndpoints {
    <#
    .SYNOPSIS
        Scans source files for API route/endpoint declarations using language-specific regex patterns.
        Returns array of @{ Method; Path; File; Language } objects.
    #>
    param([string]$WorkDir)

    Write-Step "Scanning code for API endpoint declarations..." "INFO"

    $endpoints = @()

    Push-Location $WorkDir
    try {
        foreach ($glob in $script:ROUTE_PATTERNS.Keys) {
            $files = git ls-files $glob 2>$null
            if (-not $files) { continue }

            $fileList = @($files -split "`n" | Where-Object { $_ -and $_ -notmatch $script:DEFAULT_EXCLUDES })

            foreach ($relPath in $fileList) {
                $fullPath = Join-Path $WorkDir $relPath
                if (-not (Test-Path $fullPath)) { continue }

                $content = Get-Content $fullPath -Raw -ErrorAction SilentlyContinue
                if (-not $content) { continue }

                foreach ($pattern in $script:ROUTE_PATTERNS[$glob]) {
                    $matches_ = [regex]::Matches($content, $pattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
                    foreach ($m in $matches_) {
                        $method = "UNKNOWN"
                        $path = ""

                        # Extract method and path from capture groups
                        if ($m.Groups.Count -ge 3 -and $m.Groups[2].Success) {
                            $method = $m.Groups[1].Value.ToUpper()
                            $path = $m.Groups[2].Value
                        }
                        elseif ($m.Groups.Count -ge 2 -and $m.Groups[1].Success) {
                            $path = $m.Groups[1].Value
                        }

                        if ($path) {
                            $endpoints += @{
                                Method   = $method
                                Path     = $path
                                File     = $relPath
                                Language = $glob
                            }
                        }
                    }
                }
            }
        }
    }
    finally {
        Pop-Location
    }

    # Deduplicate by method+path
    $seen = @{}
    $unique = @()
    foreach ($ep in $endpoints) {
        $key = "$($ep.Method)|$($ep.Path)"
        if (-not $seen.ContainsKey($key)) {
            $seen[$key] = $true
            $unique += $ep
        }
    }

    Write-Step "Found $($unique.Count) unique endpoints in code" "OK"
    return $unique
}

function Find-SpecEndpoints {
    <#
    .SYNOPSIS
        Extracts endpoint paths from OpenAPI/Swagger spec files.
    #>
    param([string]$WorkDir, [string[]]$SpecFiles)

    $specEndpoints = @()
    $httpMethods = @('get', 'post', 'put', 'delete', 'patch', 'options', 'head')

    foreach ($specFile in $SpecFiles) {
        $fullPath = Join-Path $WorkDir $specFile
        if (-not (Test-Path $fullPath)) { continue }

        $content = Get-Content $fullPath -Raw -ErrorAction SilentlyContinue
        if (-not $content) { continue }

        $isJson = $specFile -match '\.json$'

        if ($isJson) {
            try {
                $spec = $content | ConvertFrom-Json -ErrorAction Stop
                $paths = $spec.paths
                if ($paths) {
                    foreach ($prop in $paths.PSObject.Properties) {
                        $apiPath = $prop.Name
                        foreach ($method in $httpMethods) {
                            if ($prop.Value.PSObject.Properties.Name -contains $method) {
                                $specEndpoints += @{
                                    Method   = $method.ToUpper()
                                    Path     = $apiPath
                                    File     = $specFile
                                    Source   = "spec"
                                }
                            }
                        }
                    }
                }
            }
            catch {
                Write-Step "Failed to parse JSON spec: $specFile" "WARN"
            }
        }
        else {
            # YAML — extract paths using regex (no YAML parser dependency)
            $pathMatches = [regex]::Matches($content, '(?m)^  (/[^\s:]+)\s*:', [System.Text.RegularExpressions.RegexOptions]::Multiline)
            foreach ($pm in $pathMatches) {
                $apiPath = $pm.Groups[1].Value
                foreach ($method in $httpMethods) {
                    if ($content -match "(?m)^\s{4}$method\s*:") {
                        $specEndpoints += @{
                            Method   = $method.ToUpper()
                            Path     = $apiPath
                            File     = $specFile
                            Source   = "spec"
                        }
                    }
                }
            }
        }
    }

    Write-Step "Found $($specEndpoints.Count) endpoints in spec files" "OK"
    return $specEndpoints
}

function Invoke-Discovery {
    <#
    .SYNOPSIS
        Phase 2 orchestrator — finds specs, code endpoints, and cross-references them.
    #>
    param([string]$WorkDir)

    Write-Phase "PHASE 2" "Discovery — Finding API Specs and Code Endpoints"

    # Step 1: Find spec files
    $specFiles = Find-ApiSpecFiles -WorkDir $WorkDir

    # Step 2: Find code endpoints
    $codeEndpoints = Find-CodeEndpoints -WorkDir $WorkDir

    # Step 3: Extract spec endpoints
    $specEndpoints = @()
    if ($specFiles.Count -gt 0) {
        $specEndpoints = Find-SpecEndpoints -WorkDir $WorkDir -SpecFiles $specFiles
    }

    # Step 4: Cross-reference — find gaps
    $gaps = @()

    # Normalize paths for comparison
    $specPaths = @($specEndpoints | ForEach-Object { $_.Path.TrimEnd('/').ToLower() }) | Sort-Object -Unique
    $codePaths = @($codeEndpoints | ForEach-Object { $_.Path.TrimEnd('/').ToLower() }) | Sort-Object -Unique

    # Endpoints in code but NOT in specs
    foreach ($ep in $codeEndpoints) {
        $normalized = $ep.Path.TrimEnd('/').ToLower()
        if ($normalized -notin $specPaths) {
            $gaps += @{
                Type     = "CODE_NOT_IN_SPEC"
                Method   = $ep.Method
                Path     = $ep.Path
                File     = $ep.File
                Severity = "HIGH"
                Reason   = "Endpoint exists in code but has no API spec documentation"
            }
        }
    }

    # Endpoints in specs but NOT in code
    foreach ($ep in $specEndpoints) {
        $normalized = $ep.Path.TrimEnd('/').ToLower()
        if ($normalized -notin $codePaths) {
            $gaps += @{
                Type     = "SPEC_NOT_IN_CODE"
                Method   = $ep.Method
                Path     = $ep.Path
                File     = $ep.File
                Severity = "MEDIUM"
                Reason   = "Endpoint defined in spec but no matching route found in code"
            }
        }
    }

    # Display summary
    Write-Host ""
    Write-Host "  🔍 Cross-Reference Results" -ForegroundColor Cyan
    Write-Host "  ├─ Spec files:       $($specFiles.Count)" -ForegroundColor DarkGray
    Write-Host "  ├─ Spec endpoints:   $($specEndpoints.Count)" -ForegroundColor DarkGray
    Write-Host "  ├─ Code endpoints:   $($codeEndpoints.Count)" -ForegroundColor DarkGray
    $codeNotSpec = @($gaps | Where-Object { $_.Type -eq "CODE_NOT_IN_SPEC" }).Count
    $specNotCode = @($gaps | Where-Object { $_.Type -eq "SPEC_NOT_IN_CODE" }).Count
    Write-Host "  ├─ In code, not spec: $codeNotSpec" -ForegroundColor $(if ($codeNotSpec -gt 0) { "Yellow" } else { "Green" })
    Write-Host "  └─ In spec, not code: $specNotCode" -ForegroundColor $(if ($specNotCode -gt 0) { "Yellow" } else { "Green" })

    if ($gaps.Count -gt 0) {
        Write-Host ""
        Write-Host "  ┌──────────────────────┬────────┬─────────────────────────────────────────────┐" -ForegroundColor DarkGray
        Write-Host "  │ Type                 │ Method │ Path                                        │" -ForegroundColor DarkGray
        Write-Host "  ├──────────────────────┼────────┼─────────────────────────────────────────────┤" -ForegroundColor DarkGray
        foreach ($g in $gaps | Select-Object -First 25) {
            $path = $g.Path
            if ($path.Length -gt 43) { $path = "..." + $path.Substring($path.Length - 40) }
            $typeColor = if ($g.Type -eq "CODE_NOT_IN_SPEC") { "Yellow" } else { "Cyan" }
            Write-Host ("  │ {0,-20} │ {1,-6} │ {2,-43} │" -f $g.Type, $g.Method, $path) -ForegroundColor $typeColor
        }
        if ($gaps.Count -gt 25) {
            Write-Host "  │ ... and $($gaps.Count - 25) more                                                    │" -ForegroundColor DarkGray
        }
        Write-Host "  └──────────────────────┴────────┴─────────────────────────────────────────────┘" -ForegroundColor DarkGray
    }

    return @{
        SpecFiles      = $specFiles
        SpecEndpoints  = $specEndpoints
        CodeEndpoints  = $codeEndpoints
        Gaps           = $gaps
    }
}

# ─────────────────────────────────────────────
# Region: Phase 3 — Question Generation
# ─────────────────────────────────────────────

function New-ContractQuestions {
    <#
    .SYNOPSIS
        Generates questions about API contract gaps and endpoint documentation.
        Batches multiple gaps/endpoints per Copilot call for efficiency.
    #>
    param(
        [hashtable]$Discovery,
        [string]$WorkingDirectory,
        [int]$GapBatchSize = 10
    )

    Write-Phase "PHASE 3" "Question Generation — API Contract Gaps (batch size $GapBatchSize)"

    $allQuestions = @()
    $questionHashes = @{}

    # ── Helper: parse questions from copilot output ──
    function Parse-QuestionsFromOutput {
        param([string]$RawOutput)
        $questions = @()
        try {
            $output = $RawOutput.Trim()
            if ($output -match '```(?:json)?\s*\n?([\s\S]*?)\n?\s*```') { $output = $Matches[1].Trim() }
            if ($output -match '\[[\s\S]*\]') { $questions = @($Matches[0] | ConvertFrom-Json) }
        }
        catch {
            $questions = @()
            $lines = $RawOutput -split "`n"
            foreach ($line in $lines) {
                if ($line -match '^\s*\d+[\.\)]\s*(.+)') { $questions += $Matches[1].Trim() }
            }
        }
        return ,$questions
    }

    # ── Helper: dedup hash ──
    function Get-QHash { param([string]$Text)
        [System.BitConverter]::ToString(
            [System.Security.Cryptography.SHA256]::Create().ComputeHash(
                [System.Text.Encoding]::UTF8.GetBytes($Text.ToLower().Trim())
            )
        ).Substring(0, 16)
    }

    # ── Helper: single-gap fallback ──
    function Invoke-SingleGap {
        param($Gap)
        $direction = if ($Gap.Type -eq "CODE_NOT_IN_SPEC") { "code" } else { "spec" }
        $missing   = if ($Gap.Type -eq "CODE_NOT_IN_SPEC") { "spec" } else { "code" }
        $genPrompt = @"
Endpoint [$($Gap.Method) $($Gap.Path)] exists in $direction (file: $($Gap.File)) but not in $missing.
This is an API contract gap.

Generate exactly $QuestionsPerEndpoint questions about this API contract gap that would trigger documentation updates.
Focus on: why this gap exists, what the correct contract should be, request/response schema, error codes, and authentication.

Output ONLY a JSON array of strings. No explanation, no markdown fences.
"@
        $result = Invoke-CopilotWithRetry -Prompt $genPrompt -ModelName $script:SelectedModel `
            -WorkingDirectory $WorkingDirectory -Retries $MaxRetries -BaseDelay $RetryBaseDelay -Timeout $CallTimeout
        if ($result -and $result.Success) {
            $parsed = Parse-QuestionsFromOutput -RawOutput $result.Output
            foreach ($q in $parsed) {
                $hash = Get-QHash -Text $q
                if (-not $questionHashes.ContainsKey($hash)) {
                    $questionHashes[$hash] = $true
                    $allQuestions += @{ EntryPoint = $Gap.File; Question = $q; Category = $Gap.Type }
                }
            }
            Set-Variable -Name allQuestions -Value $allQuestions -Scope 1
            Set-Variable -Name questionHashes -Value $questionHashes -Scope 1
        }
    }

    # ── Helper: single-endpoint fallback ──
    function Invoke-SingleEndpoint {
        param($Ep)
        $genPrompt = @"
Endpoint [$($Ep.Method) $($Ep.Path)] in file $($Ep.File).
Generate exactly 2 questions about this endpoint covering:
- Error responses and status codes
- Authentication/authorization requirements
- Request/response schema documentation

Output ONLY a JSON array of strings. No explanation, no markdown fences.
"@
        $result = Invoke-CopilotWithRetry -Prompt $genPrompt -ModelName $script:SelectedModel `
            -WorkingDirectory $WorkingDirectory -Retries $MaxRetries -BaseDelay $RetryBaseDelay -Timeout $CallTimeout
        if ($result -and $result.Success) {
            $parsed = Parse-QuestionsFromOutput -RawOutput $result.Output
            foreach ($q in $parsed) {
                $hash = Get-QHash -Text $q
                if (-not $questionHashes.ContainsKey($hash)) {
                    $questionHashes[$hash] = $true
                    $allQuestions += @{ EntryPoint = $Ep.File; Question = $q; Category = "ENDPOINT_DOC" }
                }
            }
            Set-Variable -Name allQuestions -Value $allQuestions -Scope 1
            Set-Variable -Name questionHashes -Value $questionHashes -Scope 1
        }
    }

    $earlyExit = $false

    # ── 1. Gap questions: endpoints missing from spec or code ──
    $batches = @()
    for ($i = 0; $i -lt $Discovery.Gaps.Count; $i += $GapBatchSize) {
        $end = [Math]::Min($i + $GapBatchSize, $Discovery.Gaps.Count)
        $batches += ,@($Discovery.Gaps[$i..($end - 1)])
    }
    $totalBatches = $batches.Count
    $batchNum = 0
    foreach ($batch in $batches) {
        $batchNum++
        Write-Progress -Activity "Generating contract questions" -Status "Gap Batch $batchNum/$totalBatches ($($batch.Count) gaps)" -PercentComplete ([Math]::Round(($batchNum / [Math]::Max($totalBatches, 1)) * 100))

        # Build multi-gap prompt
        $gapsBlock = ""
        $gIdx = 0
        foreach ($g in $batch) {
            $gIdx++
            $direction = if ($g.Type -eq "CODE_NOT_IN_SPEC") { "code" } else { "spec" }
            $missing   = if ($g.Type -eq "CODE_NOT_IN_SPEC") { "spec" } else { "code" }
            $gapsBlock += "$gIdx. [$($g.Method) $($g.Path)] exists in $direction (file: $($g.File)) but not in $missing`n"
        }
        $totalExpected = $batch.Count * $QuestionsPerEndpoint
        $genPrompt = @"
These API contract gaps were found:
$gapsBlock
For EACH gap, generate exactly $QuestionsPerEndpoint questions about the API contract gap that would trigger documentation updates.
Focus on: why this gap exists, what the correct contract should be, request/response schema, error codes, and authentication.
Output ONLY a JSON array of strings ($totalExpected total). No explanation, no markdown fences.
"@
        Write-Step "[Gap Batch $batchNum/$totalBatches] Generating questions for $($batch.Count) gaps..." "INFO"
        $result = Invoke-CopilotWithRetry -Prompt $genPrompt -ModelName $script:SelectedModel `
            -WorkingDirectory $WorkingDirectory -Retries $MaxRetries -BaseDelay $RetryBaseDelay -Timeout $CallTimeout

        if (-not $result -or -not $result.Success) {
            Write-Step "[Gap Batch $batchNum] Batch call failed — falling back to per-gap" "WARN"
            foreach ($g in $batch) {
                Invoke-SingleGap -Gap $g
                if ($MaxQuestions -gt 0 -and $allQuestions.Count -ge $MaxQuestions) { $earlyExit = $true; break }
            }
            if ($earlyExit) { Write-Step "Reached MaxQuestions cap ($MaxQuestions) — stopping early" "OK"; break }
            continue
        }

        $questions = Parse-QuestionsFromOutput -RawOutput $result.Output
        if ($questions.Count -eq 0) {
            Write-Step "[Gap Batch $batchNum] No questions parsed — falling back to per-gap" "WARN"
            foreach ($g in $batch) {
                Invoke-SingleGap -Gap $g
                if ($MaxQuestions -gt 0 -and $allQuestions.Count -ge $MaxQuestions) { $earlyExit = $true; break }
            }
            if ($earlyExit) { Write-Step "Reached MaxQuestions cap ($MaxQuestions) — stopping early" "OK"; break }
            continue
        }

        # Round-robin distribute questions to batch items
        $qPerGap = $QuestionsPerEndpoint
        for ($qi = 0; $qi -lt $questions.Count; $qi++) {
            $gapIdx = [Math]::Min([Math]::Floor($qi / $qPerGap), $batch.Count - 1)
            $g = $batch[$gapIdx]
            $hash = Get-QHash -Text $questions[$qi]
            if (-not $questionHashes.ContainsKey($hash)) {
                $questionHashes[$hash] = $true
                $allQuestions += @{ EntryPoint = $g.File; Question = $questions[$qi]; Category = $g.Type }
            }
        }
        Write-Step "[Gap Batch $batchNum] +$($questions.Count) questions ($($allQuestions.Count) total)" "OK"
        if ($MaxQuestions -gt 0 -and $allQuestions.Count -ge $MaxQuestions) {
            Write-Step "Reached MaxQuestions cap ($MaxQuestions) — stopping early" "OK"; $earlyExit = $true; break
        }
    }

    # ── 2. Endpoint documentation questions ──
    if (-not $earlyExit) {
        $endpointSample = $Discovery.CodeEndpoints
        if ($endpointSample.Count -gt 30) {
            $endpointSample = $endpointSample | Sort-Object { Get-Random } | Select-Object -First 30
        }

        $batches = @()
        for ($i = 0; $i -lt $endpointSample.Count; $i += $GapBatchSize) {
            $end = [Math]::Min($i + $GapBatchSize, $endpointSample.Count)
            $batches += ,@($endpointSample[$i..($end - 1)])
        }
        $totalBatches = $batches.Count
        $batchNum = 0
        foreach ($batch in $batches) {
            $batchNum++
            Write-Progress -Activity "Generating contract questions" -Status "Endpoint Batch $batchNum/$totalBatches ($($batch.Count) endpoints)" -PercentComplete ([Math]::Round(($batchNum / [Math]::Max($totalBatches, 1)) * 100))

            $epsBlock = ""
            $eIdx = 0
            foreach ($ep in $batch) {
                $eIdx++
                $epsBlock += "$eIdx. [$($ep.Method) $($ep.Path)] in file $($ep.File)`n"
            }
            $totalExpected = $batch.Count * 2
            $genPrompt = @"
These API endpoints exist in the codebase:
$epsBlock
For EACH endpoint, generate exactly 2 questions covering:
- Error responses and status codes
- Authentication/authorization requirements
- Request/response schema documentation
Output ONLY a JSON array of strings ($totalExpected total). No explanation, no markdown fences.
"@
            Write-Step "[Endpoint Batch $batchNum/$totalBatches] Generating questions for $($batch.Count) endpoints..." "INFO"
            $result = Invoke-CopilotWithRetry -Prompt $genPrompt -ModelName $script:SelectedModel `
                -WorkingDirectory $WorkingDirectory -Retries $MaxRetries -BaseDelay $RetryBaseDelay -Timeout $CallTimeout

            if (-not $result -or -not $result.Success) {
                Write-Step "[Endpoint Batch $batchNum] Batch call failed — falling back to per-endpoint" "WARN"
                foreach ($ep in $batch) {
                    Invoke-SingleEndpoint -Ep $ep
                    if ($MaxQuestions -gt 0 -and $allQuestions.Count -ge $MaxQuestions) { $earlyExit = $true; break }
                }
                if ($earlyExit) { Write-Step "Reached MaxQuestions cap ($MaxQuestions) — stopping early" "OK"; break }
                continue
            }

            $questions = Parse-QuestionsFromOutput -RawOutput $result.Output
            if ($questions.Count -eq 0) {
                Write-Step "[Endpoint Batch $batchNum] No questions parsed — falling back to per-endpoint" "WARN"
                foreach ($ep in $batch) {
                    Invoke-SingleEndpoint -Ep $ep
                    if ($MaxQuestions -gt 0 -and $allQuestions.Count -ge $MaxQuestions) { $earlyExit = $true; break }
                }
                if ($earlyExit) { Write-Step "Reached MaxQuestions cap ($MaxQuestions) — stopping early" "OK"; break }
                continue
            }

            # Round-robin distribute: 2 questions per endpoint
            for ($qi = 0; $qi -lt $questions.Count; $qi++) {
                $epIdx = [Math]::Min([Math]::Floor($qi / 2), $batch.Count - 1)
                $ep = $batch[$epIdx]
                $hash = Get-QHash -Text $questions[$qi]
                if (-not $questionHashes.ContainsKey($hash)) {
                    $questionHashes[$hash] = $true
                    $allQuestions += @{ EntryPoint = $ep.File; Question = $questions[$qi]; Category = "ENDPOINT_DOC" }
                }
            }
            Write-Step "[Endpoint Batch $batchNum] +$($questions.Count) questions ($($allQuestions.Count) total)" "OK"
            if ($MaxQuestions -gt 0 -and $allQuestions.Count -ge $MaxQuestions) {
                Write-Step "Reached MaxQuestions cap ($MaxQuestions) — stopping early" "OK"; break
            }
        }
    }

    Write-Progress -Activity "Generating contract questions" -Completed

    # Shuffle, save
    $allQuestions = $allQuestions | Sort-Object { Get-Random }
    $questionsPath = Join-Path $script:OutputPath "questions.json"
    $allQuestions | ConvertTo-Json -Depth 5 | Set-Content $questionsPath -Encoding UTF8
    Write-Step "Saved $($allQuestions.Count) contract questions to questions.json" "OK"

    return $allQuestions
}

# ─────────────────────────────────────────────
# Region: Main Orchestrator
# ─────────────────────────────────────────────

function Start-KingLouie {
    $startTime = Get-Date

    try {
        # ── Phase 1: Setup — mode split ──
        if (-not $Internal) {
            Write-MonkeyBanner -Name $script:MONKEY_NAME -Emoji $script:MONKEY_EMOJI -Version $script:MONKEY_VERSION -Tagline $script:MONKEY_TAGLINE
            Test-Preflight
            $setup = Invoke-MonkeySetup -RepoUrl $RepoUrl -ClonePath $ClonePath -RepoPath $RepoPath `
                -BaseBranch $BaseBranch -UseBaseBranch:$UseBaseBranch -BranchName $BranchName `
                -BranchPrefix $script:MONKEY_PREFIX -OutputDirName $script:OUTPUT_DIR
            $workDir = $setup.WorkDir
            $script:BranchName = $setup.Branch
            $script:OutputPath = $setup.OutputPath
            $script:SelectedModel = Select-MonkeyModel -UserModel $Model -WorkingDirectory $workDir
            Test-CopilotInRepo -WorkingDirectory $workDir
        }
        else {
            Write-Phase "KING LOUIE" "Running in internal mode (orchestrated)"
            $workDir = $InternalRepoPath
            $script:SelectedModel = $InternalModel
            $script:OutputPath = $InternalOutputPath
            $script:BranchName = ''
            if (-not (Test-Path $script:OutputPath)) { New-Item -ItemType Directory -Path $script:OutputPath -Force | Out-Null }
            New-Item -ItemType Directory -Path (Join-Path $script:OutputPath "session-logs") -Force | Out-Null
        }

        # Fast-path: GenOnly + checkpoint exists → skip discovery entirely
        if ($GenOnly) {
            $savedQ = Get-QuestionCheckpoint -OutputPath $script:OutputPath
            if ($savedQ -and $savedQ.Count -gt 0) {
                Write-Step "Loaded $($savedQ.Count) questions from checkpoint — skipping discovery" "OK"
                return @{ Questions = $savedQ; Status = 'gen-complete'; MonkeyName = $script:MONKEY_NAME; Count = $savedQ.Count }
            }
        }

        # ── Phase 2: Discovery ──
        $discovery = Invoke-Discovery -WorkDir $workDir

        # Incremental filter
        if ($Incremental -or $Since) {
            $sinceRef = $Since
            if (-not $sinceRef) {
                $lastState = Get-IncrementalState -WorkingDirectory $workDir
                if ($lastState) {
                    $sinceRef = $lastState.CommitHash
                    Write-Step "Incremental: using last run commit $sinceRef" "INFO"
                }
                else {
                    Write-Step "No prior run found — running full" "WARN"
                }
            }
            if ($sinceRef) {
                $changedFiles = Get-ChangedFiles -WorkingDirectory $workDir -Since $sinceRef
                $discovery.CodeEndpoints = @($discovery.CodeEndpoints | Where-Object { $_.File -in $changedFiles })
                $discovery.SpecEndpoints = @($discovery.SpecEndpoints | Where-Object { $_.File -in $changedFiles })
                $discovery.Gaps = @($discovery.Gaps | Where-Object { $_.File -in $changedFiles })
                if ($discovery.Gaps.Count -eq 0 -and $discovery.CodeEndpoints.Count -eq 0) {
                    Write-Step "No endpoints changed — nothing to validate" "OK"
                    $duration = (Get-Date) - $startTime
                    return New-MonkeyResult -MonkeyName $script:MONKEY_NAME -Duration $duration `
                        -Model $script:SelectedModel -ExitStatus 'SUCCESS' -QuestionsAsked 0 -QuestionsAnswered 0
                }
            }
        }

        # Save discovery results
        $discoveryReport = @{
            SpecFiles     = $discovery.SpecFiles
            SpecEndpoints = $discovery.SpecEndpoints.Count
            CodeEndpoints = $discovery.CodeEndpoints.Count
            Gaps          = $discovery.Gaps
        }
        $discoveryReport | ConvertTo-Json -Depth 5 | Set-Content (Join-Path $script:OutputPath "discovery.json") -Encoding UTF8
        Write-Step "Discovery results saved to discovery.json" "OK"

        if ($discovery.Gaps.Count -eq 0 -and $discovery.CodeEndpoints.Count -eq 0) {
            Write-Step "No API endpoints or gaps found — nothing to validate." "WARN"
            $duration = (Get-Date) - $startTime
            return New-MonkeyResult -MonkeyName $script:MONKEY_NAME -Duration $duration `
                -Model $script:SelectedModel -ExitStatus 'SUCCESS' -QuestionsAsked 0 -QuestionsAnswered 0
        }

        # ── Phase 3: Question Generation ──
        if ($PreGenQuestions -and $PreGenQuestions.Count -gt 0) {
            $questions = $PreGenQuestions
            Write-Step "Using $($PreGenQuestions.Count) pre-generated questions" "OK"
        } else {
            $savedQ = Get-QuestionCheckpoint -OutputPath $script:OutputPath
            if ($savedQ -and $savedQ.Count -gt 0 -and -not $GenOnly) {
                $questions = $savedQ
                Write-Step "Loaded $($savedQ.Count) questions from checkpoint — skipping generation" "OK"
            } else {
                $questions = New-ContractQuestions -Discovery $discovery -WorkingDirectory $workDir -GapBatchSize $GapBatchSize
                Save-QuestionCheckpoint -OutputPath $script:OutputPath -Questions $questions
            }
        }

        if ($questions.Count -eq 0) {
            Write-Step "No questions generated." "WARN"
            $duration = (Get-Date) - $startTime
            return New-MonkeyResult -MonkeyName $script:MONKEY_NAME -Duration $duration `
                -Model $script:SelectedModel -ExitStatus 'SUCCESS' -QuestionsAsked 0 -QuestionsAnswered 0
        }

        # GenOnly mode — return questions without answering
        if ($GenOnly) {
            return @{ Questions = $questions; Status = 'gen-complete'; MonkeyName = $script:MONKEY_NAME; Count = $questions.Count }
        }

        # ── Phase 4: Execution (shared) ──
        $docDirs = Get-DocDirectories -RootDir $workDir
        $execStats = Invoke-MonkeyQuestions -Questions $questions -WorkingDirectory $workDir `
            -OutputPath $script:OutputPath -ModelName $script:SelectedModel -MonkeyEmoji $script:MONKEY_EMOJI `
            -MaxRetries $MaxRetries -RetryBaseDelay $RetryBaseDelay -CallTimeout $CallTimeout -BatchSize $BatchSize -MaxQuestions $MaxQuestions `
            -DocDirectories $docDirs -ShowVerbose:$ShowVerbose

        # ── Phase 5: Commit/Stage + Report ──
        $filesChanged = 0
        if (-not $Internal) {
            $filesChanged = Invoke-MonkeyCommit -WorkingDirectory $workDir -OutputDirName $script:OUTPUT_DIR `
                -MonkeyName $script:MONKEY_NAME -MonkeyEmoji $script:MONKEY_EMOJI -BranchName $script:BranchName `
                -ModelName $script:SelectedModel -QuestionsAnswered $execStats.Answered -DryRun:$DryRun -Commit:$Commit
        }

        $duration = (Get-Date) - $startTime
        $reportStats = Save-MonkeyReport -ExecStats $execStats -OutputPath $script:OutputPath -MonkeyName $script:MONKEY_NAME

        $runStats = @{
            "01_SpecFiles"          = $discovery.SpecFiles.Count
            "02_SpecEndpoints"      = $discovery.SpecEndpoints.Count
            "03_CodeEndpoints"      = $discovery.CodeEndpoints.Count
            "04_ContractGaps"       = $discovery.Gaps.Count
            "05_QuestionsGenerated" = $questions.Count
            "06_QuestionsAnswered"  = $execStats.Answered
            "07_QuestionsFailed"    = $execStats.Failed
            "08_TotalRetries"       = $execStats.Retries
            "09_FilesChanged"       = $filesChanged
            "10_DocGrounded"        = $execStats.DocGroundedCount
            "11_ModelUsed"          = if ($script:SelectedModel) { $script:SelectedModel } else { "(default)" }
            "12_Branch"             = $script:BranchName
            "13_Duration"           = "{0:hh\:mm\:ss}" -f $duration
        }
        $runStats | ConvertTo-Json -Depth 3 | Set-Content (Join-Path $script:OutputPath "summary.json") -Encoding UTF8
        Write-MonkeySummary -Stats $runStats -Emoji $script:MONKEY_EMOJI
        Write-Host "  $($script:MONKEY_EMOJI) King Louie complete!" -ForegroundColor Green

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

Start-KingLouie

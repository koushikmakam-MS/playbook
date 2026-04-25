<#
.SYNOPSIS
    Mojo Jojo 🦹 — The Chaos Finder
    Scans codebase for edge cases, security issues, and crash-prone patterns,
    then asks targeted questions to trigger analysis and documentation.

.DESCRIPTION
    Phase 1: Setup (shared — clone/branch/model/preflight)
    Phase 2: Risk Scan — regex-based detection of risky code patterns
    Phase 3: Question Generation — Copilot generates questions biased by detected risks
    Phase 4: Question Execution (shared — copilot CLI with retry)
    Phase 5: Commit & Report (shared — git stage/commit + healing report)

.PARAMETER RepoUrl
    Git repository URL to clone.
.PARAMETER ClonePath
    Directory to clone into. Default: .\mojo-workspace
.PARAMETER RepoPath
    Path to an existing local repository (skip cloning).
.PARAMETER BaseBranch
    Branch to base work on. If omitted, you'll be prompted.
.PARAMETER UseBaseBranch
    Work directly on the base branch instead of creating a new one.
.PARAMETER BranchName
    Custom branch name. Default: mojo-jojo/<timestamp>
.PARAMETER DryRun
    Stage changes but don't commit.
.PARAMETER Commit
    Auto-commit changes after execution.
.PARAMETER Model
    Override Copilot model selection.
.PARAMETER QuestionsPerFile
    Max questions per risky file. Default: 5. Weighted by severity.
.PARAMETER MaxRetries
    Retry count per Copilot call. Default: 3.
.PARAMETER RetryBaseDelay
    Base delay for exponential backoff (seconds). Default: 30.
.PARAMETER CallTimeout
    Timeout per Copilot call (seconds). Default: 300.
.PARAMETER ShowVerbose
    Display Copilot output in real time.
.PARAMETER IncludeGlob
    Override file discovery globs.
.PARAMETER ExcludePattern
    Patterns to exclude from scanning.
.PARAMETER MinSeverity
    Minimum severity score to generate questions. Default: 2.
#>

[CmdletBinding()]
param(
    [string]$RepoUrl,
    [string]$ClonePath = ".\mojo-workspace",
    [string]$RepoPath,
    [string]$BaseBranch,
    [switch]$UseBaseBranch,
    [string]$BranchName,
    [switch]$DryRun,
    [switch]$Commit,
    [string]$Model,
    [int]$QuestionsPerFile = 5,
    [int]$MaxRetries = 3,
    [int]$RetryBaseDelay = 30,
    [int]$CallTimeout = 300,
    [int]$BatchSize = 5,
    [switch]$ShowVerbose,
    [string[]]$IncludeGlob,
    [string[]]$ExcludePattern = @(),
    [int]$MinSeverity = 2,

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

# ── Constants ────────────────────────────────────────────────────────
$MONKEY_NAME    = "Mojo Jojo"
$MONKEY_EMOJI   = "🦹"
$MONKEY_PREFIX  = "mojo-jojo"
$OUTPUT_DIR     = ".mojo-jojo-output"

# ── Risk Pattern Definitions ─────────────────────────────────────────
# Each pattern: Name, Category (SECURITY|EDGE_CASE|CRASH), Regex, Severity (1-5), Description
$RISK_PATTERNS = @(
    # ── SECURITY ──────────────────────────────────────────────────
    @{
        Name        = "HardcodedSecret"
        Category    = "SECURITY"
        Regex       = '(?i)(password|secret|apikey|api_key|token|connectionstring|private_key|access_key)\s*[=:]\s*["\x27][^\s"]{8,}["\x27]'
        Severity    = 5
        Description = "Potential hardcoded secret or credential"
    }
    @{
        Name        = "SqlConcatenation"
        Category    = "SECURITY"
        Regex       = '(?i)(["'']SELECT|["'']INSERT|["'']UPDATE|["'']DELETE|["'']DROP)\s.*(\+\s|#\{|\$\{|%s|%d|\.format\(|f["''])'
        Severity    = 5
        Description = "SQL query built via string interpolation/concatenation (injection risk)"
    }
    @{
        Name        = "UnsafeDeserialization"
        Category    = "SECURITY"
        Regex       = '(?i)(BinaryFormatter|ObjectStateFormatter|NetDataContractSerializer|SoapFormatter|JavaScriptSerializer|pickle\.load|yaml\.load\((?!.*Loader)|eval\(|unserialize\(|Marshal\.load|ObjectInputStream|readObject\(\))\b'
        Severity    = 4
        Description = "Unsafe deserialization method (RCE risk)"
    }
    @{
        Name        = "PathTraversal"
        Category    = "SECURITY"
        Regex       = '(?i)(Path\.Combine|File\.(Read|Write|Open|Delete|Copy|Move)|open\(|os\.path\.join|path\.join|fs\.(read|write)|File\.new)\s*\([^)]*(\+|#\{|\$\{|\%)'
        Severity    = 4
        Description = "File path built from dynamic input (path traversal risk)"
    }
    @{
        Name        = "DisabledSslValidation"
        Category    = "SECURITY"
        Regex       = '(?i)(ServerCertificateValidationCallback\s*=|ServicePointManager\.ServerCertificateValidationCallback|verify\s*=\s*False|verify_ssl\s*=\s*false|NODE_TLS_REJECT_UNAUTHORIZED|InsecureSkipVerify\s*:\s*true|verify_mode\s*=\s*VERIFY_NONE)'
        Severity    = 4
        Description = "SSL/TLS certificate validation bypassed"
    }
    @{
        Name        = "OpenCors"
        Category    = "SECURITY"
        Regex       = '(?i)(AllowAnyOrigin|Access-Control-Allow-Origin.*\*|EnableCors\s*\(\s*"\*"|cors\(\s*\)|origin:\s*["\x27]\*["\x27])'
        Severity    = 3
        Description = "Overly permissive CORS configuration"
    }
    @{
        Name        = "MissingAuthAttribute"
        Category    = "SECURITY"
        Regex       = '(?i)(\[AllowAnonymous\]|@PermitAll|skip_auth|no_auth|public\s*=\s*true)'
        Severity    = 3
        Description = "Endpoint allows unauthenticated access — verify intentional"
    }
    @{
        Name        = "WeakCrypto"
        Category    = "SECURITY"
        Regex       = '(?i)(MD5\.Create|md5\(|hashlib\.md5|SHA1\.Create|sha1\(|hashlib\.sha1|DES\.Create|RC2\.Create|new\s+TripleDES|RC4|Blowfish)'
        Severity    = 3
        Description = "Weak or deprecated cryptographic algorithm"
    }
    @{
        Name        = "CommandInjection"
        Category    = "SECURITY"
        Regex       = '(?i)(Runtime\.exec|ProcessBuilder|os\.system|subprocess\.call|exec\(|system\(|child_process\.exec|Kernel\.system|`[^`]*\$)'
        Severity    = 4
        Description = "Potential command injection — external input in shell command"
    }

    # ── EDGE CASES ────────────────────────────────────────────────
    @{
        Name        = "UnboundedCollection"
        Category    = "EDGE_CASE"
        Regex       = '(?i)(\.ToList\(\)|\.ToArray\(\)|list\(|\.fetchall\(\)|\.collect\(\))(?!.*\.(Take|Limit|limit|LIMIT|slice|first|\[:))'
        Severity    = 2
        Description = "Unbounded collection materialization (memory risk on large datasets)"
    }
    @{
        Name        = "StaticMutableState"
        Category    = "EDGE_CASE"
        Regex       = '(?i)(static\s+(?!readonly|const|final)\w+\s*(List|Dict|Hash|Map|Set|Queue|Stack|Array|Vec|Mutex)<|@@\w+\s*=\s*([\[\{]|Array|Hash)|\$\w+\s*=\s*\[\].*global)'
        Severity    = 3
        Description = "Static/global mutable state (thread-safety / race condition risk)"
    }
    @{
        Name        = "IntegerOverflow"
        Category    = "EDGE_CASE"
        Regex       = '(?i)(unchecked\s*\{|int\.MaxValue|int\.MinValue|Integer\.MAX_VALUE|Integer\.MIN_VALUE|sys\.maxsize|\(int\)\s*\w+\s*\*\s*\w+)'
        Severity    = 3
        Description = "Potential integer overflow or unchecked arithmetic"
    }
    @{
        Name        = "EmptyStringCheck"
        Category    = "EDGE_CASE"
        Regex       = '(?i)(==\s*""|\.Equals\s*\(\s*""\s*\)|===\s*["\x27]{2})'
        Severity    = 1
        Description = "Empty string comparison — consider null/whitespace-safe check"
    }
    @{
        Name        = "MagicNumber"
        Category    = "EDGE_CASE"
        Regex       = '(?i)(Thread\.Sleep|Task\.Delay|time\.sleep|time\.Sleep|setTimeout|setInterval)\s*\(\s*\d{4,}\s*\)'
        Severity    = 2
        Description = "Magic number in delay/timeout (should be configurable)"
    }
    @{
        Name        = "UnvalidatedEnum"
        Category    = "EDGE_CASE"
        Regex       = '(?i)\((\w+Enum|\w+Type|\w+Status|\w+Kind)\)\s*(int|request\.|input\.|param|args)'
        Severity    = 3
        Description = "Enum/type cast from external input without validation"
    }
    @{
        Name        = "InfiniteLoop"
        Category    = "EDGE_CASE"
        Regex       = '(?i)(while\s*\(\s*true\s*\)|while\s+True\s*:|for\s*\(\s*;\s*;\s*\)|loop\s*\{)'
        Severity    = 2
        Description = "Infinite loop — ensure break condition exists"
    }

    # ── CRASH-PRONE ───────────────────────────────────────────────
    @{
        Name        = "EmptyCatch"
        Category    = "CRASH"
        Regex       = '(catch\s*(\([^)]*\))?\s*\{\s*\}|except\s*:\s*\n\s*pass|rescue\s*\n\s*end)'
        Severity    = 4
        Description = "Empty catch/except/rescue block — exceptions swallowed silently"
    }
    @{
        Name        = "CatchWithoutLog"
        Category    = "CRASH"
        Regex       = '(catch\s*\(\s*\w+\s+\w+\s*\)\s*\{[^}]{0,50}\}|except\s+\w+(\s+as\s+\w+)?:\s*\n\s+\S[^\n]{0,40}\n)'
        Severity    = 3
        Description = "Catch/except block with minimal body — may not be logging"
    }
    @{
        Name        = "BlockingAsync"
        Category    = "CRASH"
        Regex       = '(?i)(\.(Result|GetAwaiter\(\)\.GetResult\(\))\b|\.Wait\(\)|asyncio\.get_event_loop\(\)\.run_until_complete|\.get\(\)\s*;)'
        Severity    = 4
        Description = "Blocking on async code — deadlock risk"
    }
    @{
        Name        = "MissingDispose"
        Category    = "CRASH"
        Regex       = '(?i)new\s+(HttpClient|SqlConnection|StreamReader|StreamWriter|FileStream|WebClient|TcpClient|BufferedReader|FileWriter)\s*\('
        Severity    = 3
        Description = "Disposable/closeable object created — verify using/try-with-resources/defer"
    }
    @{
        Name        = "UnsafeCast"
        Category    = "CRASH"
        Regex       = '(?i)(\(\s*(int|long|string|double|float|String)\s*\)\s*\w+|\.asInstanceOf\[|as!\s)'
        Severity    = 2
        Description = "Forced cast without safe check (ClassCastException / panic risk)"
    }
    @{
        Name        = "TaskFireAndForget"
        Category    = "CRASH"
        Regex       = '(?i)(Task\.Run\s*\([^)]*\)\s*;(?!\s*\.)|go\s+func\s*\(|threading\.Thread\(.*\)\.start\(\)|Thread\.new\s*\{)'
        Severity    = 3
        Description = "Fire-and-forget goroutine/task/thread (unobserved exceptions)"
    }
    @{
        Name        = "ThrowInFinally"
        Category    = "CRASH"
        Regex       = '(finally\s*\{[^}]*throw\b|ensure\s*\n[^#]*raise\b)'
        Severity    = 4
        Description = "Throw/raise in finally/ensure block — original exception lost"
    }
    @{
        Name        = "PanicInProduction"
        Category    = "CRASH"
        Regex       = '(?i)(panic\(|unwrap\(\)|expect\(["\x27]|os\.Exit\(|System\.exit\(|process\.exit\()'
        Severity    = 3
        Description = "Panic/exit/unwrap in production code — consider graceful error handling"
    }
    @{
        Name        = "NullDerefChain"
        Category    = "CRASH"
        Regex       = '(?i)(\w+\.\w+\.\w+\.\w+)(?!\s*\?\.)' 
        Severity    = 2
        Description = "Deep member access chain — null/nil reference risk"
        SkipAlone   = $true
    }
)

# ── Language-aware file patterns ─────────────────────────────────────
$SCAN_PATTERNS = @{
    "C#"         = @("*.cs")
    "Java"       = @("*.java")
    "Kotlin"     = @("*.kt")
    "Python"     = @("*.py")
    "JavaScript" = @("*.js", "*.ts", "*.jsx", "*.tsx")
    "Go"         = @("*.go")
    "Ruby"       = @("*.rb")
    "PHP"        = @("*.php")
    "Rust"       = @("*.rs")
}

# Default excludes (test files, generated, vendor, migrations)
$DEFAULT_EXCLUDES = @(
    "*test*", "*Test*", "*spec*", "*Spec*",
    "*.Designer.cs", "*.generated.*",
    "*\obj\*", "*\bin\*", "*\node_modules\*", "*\vendor\*",
    "*\packages\*", "*\migrations\*", "*\.git\*",
    "*AssemblyInfo*", "*GlobalSuppressions*",
    "*\target\*", "*\.gradle\*", "*\dist\*", "*\build\*",
    "*__pycache__*", "*\.mojo-jojo-output\*",
    "*\.rafiki-output\*", "*\.abu-output\*", "*\.monkey-output\*"
)

# ── Phase 2: Risk Scan ──────────────────────────────────────────────

function Get-ScanFiles {
    <#
    .SYNOPSIS
        Discovers source files to scan, respecting includes/excludes.
    #>
    param([string]$WorkDir)

    $files = @()
    $globs = if ($IncludeGlob) { $IncludeGlob } else {
        $SCAN_PATTERNS.Values | ForEach-Object { $_ } | Sort-Object -Unique
    }

    foreach ($glob in $globs) {
        $found = Get-ChildItem -Path $WorkDir -Filter $glob -Recurse -File -ErrorAction SilentlyContinue
        $files += $found
    }

    # Apply excludes
    $allExcludes = $DEFAULT_EXCLUDES + $ExcludePattern
    $filtered = @($files | Where-Object {
        $path = $_.FullName
        $excluded = $false
        foreach ($pattern in $allExcludes) {
            if ($path -like $pattern) { $excluded = $true; break }
        }
        -not $excluded
    } | Sort-Object FullName -Unique)

    return $filtered
}

function Invoke-RiskScan {
    <#
    .SYNOPSIS
        Scans files for risky code patterns. Returns array of risk findings per file.
    #>
    param([System.IO.FileInfo[]]$Files, [string]$WorkDir)

    Write-Phase "PHASE 2" "Risk Scan — Scanning $($Files.Count) files for security, edge case, and crash patterns"

    $fileRisks = @()
    $totalFindings = 0
    $progressCount = 0

    foreach ($file in $Files) {
        $progressCount++
        if ($progressCount % 50 -eq 0) {
            Write-Host "  📂 Scanned $progressCount / $($Files.Count) files..." -ForegroundColor DarkGray
        }

        try {
            $content = Get-Content $file.FullName -Raw -ErrorAction Stop
            if (-not $content -or $content.Length -lt 20) { continue }
        }
        catch { continue }

        $lines = $content -split "`n"
        $findings = @()

        foreach ($pattern in $RISK_PATTERNS) {
            $matches = [regex]::Matches($content, $pattern.Regex, [System.Text.RegularExpressions.RegexOptions]::Multiline)
            if ($matches.Count -eq 0) { continue }

            # Find line numbers for matches
            $matchLines = @()
            foreach ($m in $matches) {
                $beforeMatch = $content.Substring(0, $m.Index)
                $lineNum = ($beforeMatch -split "`n").Count
                $matchLines += @{
                    Line    = $lineNum
                    Snippet = $lines[[Math]::Max(0, $lineNum - 1)].Trim().Substring(0, [Math]::Min(120, $lines[[Math]::Max(0, $lineNum - 1)].Trim().Length))
                }
            }

            $findings += @{
                Pattern     = $pattern.Name
                Category    = $pattern.Category
                Severity    = $pattern.Severity
                Description = $pattern.Description
                MatchCount  = $matches.Count
                Lines       = $matchLines
                SkipAlone   = if ($pattern.SkipAlone) { $true } else { $false }
            }
        }

        if ($findings.Count -eq 0) { continue }

        # Calculate file severity score
        $severityScore = 0
        $hasNonSkipFinding = $false
        foreach ($f in $findings) {
            $severityScore += $f.Severity * $f.MatchCount
            if (-not $f.SkipAlone) { $hasNonSkipFinding = $true }
        }

        # Skip files that only have SkipAlone patterns
        if (-not $hasNonSkipFinding) { continue }

        $relativePath = $file.FullName.Replace($WorkDir, "").TrimStart("\", "/")
        $totalFindings += $findings.Count

        $fileRisks += @{
            File          = $relativePath
            FullPath      = $file.FullName
            SeverityScore = $severityScore
            FindingCount  = $findings.Count
            Findings      = $findings
            Categories    = @($findings | ForEach-Object { $_.Category } | Sort-Object -Unique)
        }
    }

    # Sort by severity (highest risk first)
    $fileRisks = @($fileRisks | Sort-Object { $_.SeverityScore } -Descending)

    # Summary
    $securityCount = @($fileRisks | Where-Object { $_.Categories -contains "SECURITY" }).Count
    $edgeCaseCount = @($fileRisks | Where-Object { $_.Categories -contains "EDGE_CASE" }).Count
    $crashCount    = @($fileRisks | Where-Object { $_.Categories -contains "CRASH" }).Count

    Write-Host ""
    Write-Host "  🔍 Risk Scan Complete" -ForegroundColor Cyan
    Write-Host "  ├─ Files scanned: $($Files.Count)" -ForegroundColor DarkGray
    Write-Host "  ├─ Risky files:   $($fileRisks.Count)" -ForegroundColor $(if ($fileRisks.Count -gt 0) { "Yellow" } else { "Green" })
    Write-Host "  ├─ Total findings: $totalFindings" -ForegroundColor DarkGray
    Write-Host "  ├─ 🔒 Security:   $securityCount files" -ForegroundColor $(if ($securityCount -gt 0) { "Red" } else { "Green" })
    Write-Host "  ├─ ⚠️  Edge Cases:  $edgeCaseCount files" -ForegroundColor $(if ($edgeCaseCount -gt 0) { "Yellow" } else { "Green" })
    Write-Host "  └─ 💥 Crash-Prone: $crashCount files" -ForegroundColor $(if ($crashCount -gt 0) { "Magenta" } else { "Green" })

    # Show top 10 riskiest files
    if ($fileRisks.Count -gt 0) {
        Write-Host ""
        Write-Host "  Top risky files:" -ForegroundColor White
        $top = @($fileRisks | Select-Object -First 10)
        foreach ($r in $top) {
            $cats = ($r.Categories | ForEach-Object {
                switch ($_) {
                    "SECURITY"  { "🔒" }
                    "EDGE_CASE" { "⚠️" }
                    "CRASH"     { "💥" }
                }
            }) -join ""
            Write-Host "  $cats [score:$($r.SeverityScore)] $($r.File)" -ForegroundColor DarkYellow
        }
    }

    return $fileRisks
}

# ── Phase 3: Question Generation ─────────────────────────────────────

function New-RiskQuestions {
    <#
    .SYNOPSIS
        Generates targeted questions for risky files using Copilot.
        Questions are biased by detected risk patterns.
    #>
    param(
        [array]$FileRisks,
        [string]$WorkDir,
        [string]$SelectedModel
    )

    # Filter by minimum severity
    $eligible = @($FileRisks | Where-Object { $_.SeverityScore -ge $MinSeverity })
    if ($eligible.Count -eq 0) {
        Write-Host "  ⚠️ No files meet minimum severity threshold ($MinSeverity). Adjust -MinSeverity?" -ForegroundColor Yellow
        return @()
    }

    Write-Phase "PHASE 3" "Question Generation — Generating questions for $($eligible.Count) risky files"

    # Weight questions by severity score (more risk → more questions)
    $totalSeverity = ($eligible | Measure-Object -Property SeverityScore -Sum).Sum
    if ($totalSeverity -eq 0) { $totalSeverity = 1 }

    $allQuestions = @()
    $generated = 0

    foreach ($risk in $eligible) {
        $generated++

        # Weighted question count: proportional to severity, min 1, max QuestionsPerFile
        $proportion = $risk.SeverityScore / $totalSeverity
        $qCount = [Math]::Max(1, [Math]::Min($QuestionsPerFile, [Math]::Ceiling($proportion * $eligible.Count * $QuestionsPerFile / $eligible.Count * 2)))
        $qCount = [Math]::Min($qCount, $QuestionsPerFile)

        # Build risk context for the prompt
        $riskContext = @()
        foreach ($finding in $risk.Findings) {
            $lineExamples = @($finding.Lines | Select-Object -First 3 | ForEach-Object { "Line $($_.Line): $($_.Snippet)" }) -join "; "
            $riskContext += "- [$($finding.Category)] $($finding.Description) ($($finding.MatchCount) occurrences): $lineExamples"
        }
        $riskContextStr = $riskContext -join "`n"

        $prompt = @"
You are a security and reliability analyst. I found these risky patterns in the file '$($risk.File)':

$riskContextStr

Generate exactly $qCount targeted questions that would help identify, document, or fix these risks.

RULES:
- Questions must reference the SPECIFIC file and patterns found
- Mix question types: "Is this pattern safe because...", "What happens if...", "How should we fix..."
- Prioritize SECURITY > CRASH > EDGE_CASE
- Each question should be self-contained and actionable
- Questions should trigger documentation of error handling, security decisions, and edge case behavior

Return as JSON array: [{"question":"...", "category":"SECURITY|EDGE_CASE|CRASH", "target_pattern":"PatternName", "severity":"HIGH|MEDIUM|LOW"}]
Return ONLY the JSON array, no markdown fences, no explanation.
"@

        Write-Host "  [$generated/$($eligible.Count)] Generating $qCount questions for $($risk.File)..." -ForegroundColor DarkGray

        $response = Invoke-CopilotWithRetry -Prompt $prompt -WorkingDirectory $WorkDir `
            -ModelName $SelectedModel -Retries $MaxRetries `
            -BaseDelay $RetryBaseDelay -Timeout $CallTimeout `
            -ShowVerbose:$ShowVerbose

        if (-not $response -or -not $response.Success -or -not $response.Output.Trim()) {
            Write-Host "    ⚠️ Empty response, skipping" -ForegroundColor Yellow
            continue
        }

        # Parse response — try JSON first, fallback to line extraction
        $questions = @()
        try {
            $cleaned = $response.Output.Trim()
            # Strip markdown fences if present
            if ($cleaned -match '```(?:json)?\s*\n?([\s\S]*?)\n?\s*```') {
                $cleaned = $Matches[1].Trim()
            }
            $parsed = @($cleaned | ConvertFrom-Json)
            foreach ($q in $parsed) {
                $questions += @{
                    Question      = $q.question
                    Category      = if ($q.category) { $q.category } else { $risk.Categories[0] }
                    TargetPattern = if ($q.target_pattern) { $q.target_pattern } else { "General" }
                    Severity      = if ($q.severity) { $q.severity } else { "MEDIUM" }
                    SourceFile    = $risk.File
                    FileSeverity  = $risk.SeverityScore
                }
            }
        }
        catch {
            # Fallback: extract questions from lines
            $questionLines = $response.Output -split "`n" | Where-Object { $_ -match '\?\s*$' -or $_ -match '^\d+[\.\)]\s+' }
            foreach ($line in $questionLines) {
                $cleanLine = $line -replace '^\d+[\.\)]\s*', '' -replace '^\s*[-•]\s*', ''
                if ($cleanLine.Length -gt 15) {
                    $questions += @{
                        Question      = $cleanLine.Trim()
                        Category      = $risk.Categories[0]
                        TargetPattern = "General"
                        Severity      = "MEDIUM"
                        SourceFile    = $risk.File
                        FileSeverity  = $risk.SeverityScore
                    }
                }
            }
            if ($questions.Count -gt 0) {
                Write-Host "    📝 JSON parse failed, extracted $($questions.Count) questions from text" -ForegroundColor DarkYellow
            }
        }

        if ($questions.Count -eq 0) {
            Write-Host "    ⚠️ No questions extracted for $($risk.File)" -ForegroundColor Yellow
            continue
        }

        $allQuestions += $questions
        Write-Host "    ✅ $($questions.Count) questions generated" -ForegroundColor DarkGreen
    }

    # Sort: HIGH severity first, then by file severity score
    $severityOrder = @{ "HIGH" = 0; "MEDIUM" = 1; "LOW" = 2 }
    $allQuestions = @($allQuestions | Sort-Object {
        $severityOrder[$_.Severity]
    }, { -$_.FileSeverity })

    # Category breakdown
    $secQ  = @($allQuestions | Where-Object { $_.Category -eq "SECURITY" }).Count
    $edgeQ = @($allQuestions | Where-Object { $_.Category -eq "EDGE_CASE" }).Count
    $crashQ = @($allQuestions | Where-Object { $_.Category -eq "CRASH" }).Count

    Write-Host ""
    Write-Host "  📋 Question Generation Complete" -ForegroundColor Cyan
    Write-Host "  ├─ Total questions: $($allQuestions.Count)" -ForegroundColor White
    Write-Host "  ├─ 🔒 Security:    $secQ" -ForegroundColor Red
    Write-Host "  ├─ ⚠️  Edge Cases:   $edgeQ" -ForegroundColor Yellow
    Write-Host "  └─ 💥 Crash-Prone:  $crashQ" -ForegroundColor Magenta

    return $allQuestions
}

# ══════════════════════════════════════════════════════════════════════
#  MAIN EXECUTION
# ══════════════════════════════════════════════════════════════════════

$startTime = Get-Date

# ── Mode split: standalone vs internal ──
if (-not $Internal) {
    Write-MonkeyBanner -Name $MONKEY_NAME -Emoji $MONKEY_EMOJI -Version "1.0.0" -Tagline "The Chaos Finder — hunting edge cases, security holes, and crash-prone patterns"
    Test-Preflight
    $setupResult = Invoke-MonkeySetup `
        -RepoUrl $RepoUrl -ClonePath $ClonePath -RepoPath $RepoPath `
        -BaseBranch $BaseBranch -UseBaseBranch:$UseBaseBranch -BranchName $BranchName `
        -BranchPrefix $MONKEY_PREFIX -OutputDirName $OUTPUT_DIR
    $workDir = $setupResult.WorkDir
    $selectedModel = Select-MonkeyModel -UserModel $Model -WorkingDirectory $workDir
    Test-CopilotInRepo -WorkingDirectory $workDir
    $outputPath = $setupResult.OutputPath
}
else {
    Write-Phase "MOJO JOJO" "Running in internal mode (orchestrated)"
    $workDir = $InternalRepoPath
    $selectedModel = $InternalModel
    $outputPath = $InternalOutputPath
    if (-not (Test-Path $outputPath)) { New-Item -ItemType Directory -Path $outputPath -Force | Out-Null }
    New-Item -ItemType Directory -Path (Join-Path $outputPath "session-logs") -Force | Out-Null
}

$sessionLogsDir = Join-Path $outputPath "session-logs"

# ── Phase 2: Risk Scan ───────────────────────────────────────────────
$scanFiles = Get-ScanFiles -WorkDir $workDir
if ($scanFiles.Count -eq 0) {
    Write-Host "❌ No source files found to scan." -ForegroundColor Red
    exit 1
}
Write-Host "  📁 Found $($scanFiles.Count) source files to scan" -ForegroundColor DarkGray

$fileRisks = Invoke-RiskScan -Files $scanFiles -WorkDir $workDir

if ($fileRisks.Count -eq 0) {
    Write-Host ""
    Write-Host "  ✅ No risky patterns found! Codebase looks clean." -ForegroundColor Green
    exit 0
}

# Save risk scan results
$riskScanPath = Join-Path $outputPath "risk-scan.json"
$fileRisks | ConvertTo-Json -Depth 10 | Set-Content $riskScanPath -Encoding UTF8
Write-Host "  💾 Risk scan saved: $riskScanPath" -ForegroundColor DarkGray

# ── Phase 3: Question Generation ─────────────────────────────────────
$questions = New-RiskQuestions -FileRisks $fileRisks -WorkDir $workDir -SelectedModel $selectedModel

if ($questions.Count -eq 0) {
    Write-Host "❌ No questions generated. Check risk scan results." -ForegroundColor Red
    exit 1
}

# Save questions
$questionsPath = Join-Path $outputPath "questions.json"
$questions | ConvertTo-Json -Depth 10 | Set-Content $questionsPath -Encoding UTF8
Write-Host "  💾 Questions saved: $questionsPath" -ForegroundColor DarkGray

# ── Phase 4: Question Execution (shared) ─────────────────────────────
# Transform questions into the format expected by shared Invoke-MonkeyQuestions
$monkeyQuestions = @()
$idx = 0
foreach ($q in $questions) {
    $idx++
    $monkeyQuestions += @{
        Index        = $idx
        EntryPoint   = $q.SourceFile
        Category     = $q.Category
        Question     = $q.Question
        Severity     = $q.Severity
        TargetPattern = $q.TargetPattern
    }
}

$results = Invoke-MonkeyQuestions `
    -Questions $monkeyQuestions `
    -WorkingDirectory $workDir `
    -OutputPath $outputPath `
    -ModelName $selectedModel `
    -MonkeyEmoji $MONKEY_EMOJI `
    -MaxRetries $MaxRetries `
    -RetryBaseDelay $RetryBaseDelay `
    -CallTimeout $CallTimeout `
    -BatchSize $BatchSize `
    -ShowVerbose:$ShowVerbose

# ── Phase 5: Commit & Report ─────────────────────────────────────────
$filesChanged = 0
if (-not $Internal) {
    $filesChanged = Invoke-MonkeyCommit `
        -WorkingDirectory $workDir `
        -OutputDirName $OUTPUT_DIR `
        -MonkeyName $MONKEY_NAME `
        -MonkeyEmoji $MONKEY_EMOJI `
        -BranchName $(if ($Internal) { '' } else { $setupResult.Branch }) `
        -ModelName $selectedModel `
        -QuestionsAnswered $results.Answered `
        -DryRun:$DryRun `
        -Commit:$Commit
}

$reportStats = Save-MonkeyReport -ExecStats $results -OutputPath $outputPath -MonkeyName $MONKEY_NAME

$elapsed = (Get-Date) - $startTime
Write-Host ""
Write-Host "  $MONKEY_EMOJI $MONKEY_NAME complete! Elapsed: $($elapsed.ToString('hh\:mm\:ss'))" -ForegroundColor Cyan

# Return standardized result
return New-MonkeyResult -MonkeyName $MONKEY_NAME -Duration $elapsed `
    -Model $selectedModel -ExitStatus 'SUCCESS' `
    -QuestionsAsked $monkeyQuestions.Count -QuestionsAnswered $results.Answered `
    -DocRefsFound $results.DocGroundedCount -FilesModified $filesChanged `
    -DocsGroundedPct $reportStats.DocGroundedPct -RetryCount $results.Retries

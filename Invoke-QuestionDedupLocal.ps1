<#
.SYNOPSIS
    Local-only question dedup (no LLM). For comparison against LLM-powered dedup.
.DESCRIPTION
    Uses multiple local similarity signals to find duplicates:
      1. Exact hash match
      2. Jaccard word-bag overlap
      3. Code-term overlap (PascalCase identifiers extracted from questions)
      4. Bigram overlap (2-word sequences for phrase matching)
      5. Composite score = weighted combination of all signals
.PARAMETER BenchmarkPath
    Path to benchmark-questions/ directory.
.PARAMETER CompositeThreshold
    Minimum composite score to flag as duplicate. Default 0.55.
.PARAMETER DryRun
    Show what would be deduped without modifying files.
#>

param(
    [Parameter(Mandatory)]
    [string]$BenchmarkPath,
    [string]$OutputPath,
    [double]$CompositeThreshold = 0.55,
    [switch]$DryRun
)

$ErrorActionPreference = "Stop"

# ══════════════════════════════════════════════════════════════════
#  SIMILARITY HELPERS
# ══════════════════════════════════════════════════════════════════

function Normalize-Text {
    param([string]$Text)
    $t = $Text.ToLower() -replace '[^\w\s]', '' -replace '\s+', ' '
    return $t.Trim()
}

function Get-WordSet {
    param([string]$Text)
    $words = (Normalize-Text $Text) -split '\s+' | Where-Object { $_.Length -gt 2 }
    return [System.Collections.Generic.HashSet[string]]::new([string[]]@($words | Sort-Object -Unique))
}

function Get-CodeTerms {
    # Extract PascalCase/camelCase identifiers — the semantic core of code questions
    param([string]$Text)
    $matches = [regex]::Matches($Text, '[A-Z][a-z]+(?:[A-Z][a-z]+)+|[a-z]+(?:[A-Z][a-z]+)+')
    $terms = $matches | ForEach-Object { $_.Value.ToLower() }
    return [System.Collections.Generic.HashSet[string]]::new([string[]]@($terms | Sort-Object -Unique))
}

function Get-Bigrams {
    param([string]$Text)
    $words = (Normalize-Text $Text) -split '\s+' | Where-Object { $_.Length -gt 2 }
    $bigrams = @()
    for ($i = 0; $i -lt $words.Count - 1; $i++) {
        $bigrams += "$($words[$i]) $($words[$i+1])"
    }
    return [System.Collections.Generic.HashSet[string]]::new([string[]]@($bigrams | Sort-Object -Unique))
}

function Get-SetSimilarity {
    param(
        [System.Collections.Generic.HashSet[string]]$A,
        [System.Collections.Generic.HashSet[string]]$B
    )
    if ($A.Count -eq 0 -or $B.Count -eq 0) { return 0 }
    $inter = [System.Collections.Generic.HashSet[string]]::new($A)
    $inter.IntersectWith($B)
    $union = [System.Collections.Generic.HashSet[string]]::new($A)
    $union.UnionWith($B)
    if ($union.Count -eq 0) { return 0 }
    return [Math]::Round($inter.Count / $union.Count, 4)
}

function Get-CompositeScore {
    param($QA, $QB)
    $wordSim = Get-SetSimilarity $QA.Words $QB.Words
    $codeSim = Get-SetSimilarity $QA.CodeTerms $QB.CodeTerms
    $bigramSim = Get-SetSimilarity $QA.Bigrams $QB.Bigrams

    # Weighted composite: code terms matter most, then bigrams (phrase), then words
    $composite = ($wordSim * 0.25) + ($codeSim * 0.45) + ($bigramSim * 0.30)
    return [Math]::Round($composite, 4)
}

function Normalize-EntryPoint {
    param([string]$Path)
    return ($Path.ToLower() -replace '\\', '/' -replace '^\./', '').Trim()
}

$MonkeyPriority = @{
    'rafiki'=1; 'abu'=2; 'diddy-kong'=3; 'donkey-kong'=4; 'mojo-jojo'=5; 'marcel'=6
}

# ══════════════════════════════════════════════════════════════════
#  STAGE 0: LOAD
# ══════════════════════════════════════════════════════════════════

Write-Host ""
Write-Host "  ╔══════════════════════════════════════════════════════╗" -ForegroundColor Magenta
Write-Host "  ║       🔍 LOCAL DEDUP ENGINE (no LLM)                 ║" -ForegroundColor Magenta
Write-Host "  ╚══════════════════════════════════════════════════════╝" -ForegroundColor Magenta
Write-Host ""
Write-Host "  [STAGE 0] Loading questions..." -ForegroundColor White

$questionFiles = Get-ChildItem $BenchmarkPath -Filter "*-questions.json" -File
$allQuestions = @()

foreach ($file in $questionFiles) {
    $monkeyName = $file.BaseName -replace '-questions$', ''
    $data = Get-Content $file.FullName -Raw | ConvertFrom-Json
    $questions = if ($data.Questions) { $data.Questions } else { @($data) }

    $qIndex = 0
    foreach ($q in $questions) {
        $qIndex++
        $text = $q.Question
        $allQuestions += [PSCustomObject]@{
            Id         = "$monkeyName-Q$qIndex"
            Monkey     = $monkeyName
            Category   = if ($q.Category) { $q.Category.ToLower() } else { "auto" }
            Question   = $text
            EntryPoint = if ($q.EntryPoint) { Normalize-EntryPoint $q.EntryPoint } else { "unknown" }
            Hash       = [System.BitConverter]::ToString(
                [System.Security.Cryptography.SHA256]::Create().ComputeHash(
                    [System.Text.Encoding]::UTF8.GetBytes((Normalize-Text $text))
                )
            ).Replace("-","").Substring(0,16)
            Words      = Get-WordSet $text
            CodeTerms  = Get-CodeTerms $text
            Bigrams    = Get-Bigrams $text
            Decision   = "KEEP"
            MergedInto = $null
            Reason     = $null
            Score      = $null
        }
    }
    Write-Host "    $monkeyName : $qIndex questions" -ForegroundColor Gray
}

Write-Host "  Total: $($allQuestions.Count) questions" -ForegroundColor Green
Write-Host ""

# ══════════════════════════════════════════════════════════════════
#  STAGE 1: EXACT HASH
# ══════════════════════════════════════════════════════════════════

Write-Host "  [STAGE 1] Exact dedup..." -ForegroundColor White
$stage1 = 0
$hashGroups = $allQuestions | Group-Object Hash | Where-Object { $_.Count -gt 1 }
foreach ($g in $hashGroups) {
    $sorted = $g.Group | Sort-Object { $MonkeyPriority[$_.Monkey] }
    for ($i = 1; $i -lt $sorted.Count; $i++) {
        $sorted[$i].Decision = "REMOVED"; $sorted[$i].MergedInto = $sorted[0].Id
        $sorted[$i].Reason = "Exact match"; $sorted[$i].Score = 1.0
        $stage1++
    }
}
Write-Host "    Removed: $stage1" -ForegroundColor $(if ($stage1 -gt 0) {"Yellow"} else {"Green"})

# ══════════════════════════════════════════════════════════════════
#  STAGE 2: COMPOSITE SCORE (same file, cross-monkey)
# ══════════════════════════════════════════════════════════════════

Write-Host "  [STAGE 2] Composite similarity (threshold: $CompositeThreshold)..." -ForegroundColor White
Write-Host "    Weights: words=0.25, code-terms=0.45, bigrams=0.30" -ForegroundColor Gray

$alive = $allQuestions | Where-Object { $_.Decision -eq "KEEP" }
$fileGroups = $alive | Group-Object EntryPoint | Where-Object { $_.Count -ge 2 }

$stage2 = 0
$allPairs = @()  # collect all scored pairs for analysis

foreach ($fg in $fileGroups) {
    $members = @($fg.Group)

    for ($i = 0; $i -lt $members.Count; $i++) {
        if ($members[$i].Decision -ne "KEEP") { continue }
        for ($j = $i + 1; $j -lt $members.Count; $j++) {
            if ($members[$j].Decision -ne "KEEP") { continue }

            $score = Get-CompositeScore $members[$i] $members[$j]

            if ($score -ge 0.20) {
                # Track for analysis
                $allPairs += [PSCustomObject]@{
                    IdA = $members[$i].Id; IdB = $members[$j].Id
                    MonkeyA = $members[$i].Monkey; MonkeyB = $members[$j].Monkey
                    CatA = $members[$i].Category; CatB = $members[$j].Category
                    Score = $score
                    File = $fg.Name
                    QA = $members[$i].Question.Substring(0, [Math]::Min(80, $members[$i].Question.Length))
                    QB = $members[$j].Question.Substring(0, [Math]::Min(80, $members[$j].Question.Length))
                }
            }

            if ($score -ge $CompositeThreshold) {
                # Remove lower-priority monkey's question
                $loser = if ($MonkeyPriority[$members[$i].Monkey] -le $MonkeyPriority[$members[$j].Monkey]) {
                    $members[$j]
                } else { $members[$i] }
                $winner = if ($loser.Id -eq $members[$j].Id) { $members[$i] } else { $members[$j] }

                if ($loser.Decision -eq "KEEP") {
                    $loser.Decision = "REMOVED"
                    $loser.MergedInto = $winner.Id
                    $loser.Reason = "Composite=$score (words+code+bigrams)"
                    $loser.Score = $score
                    $stage2++
                }
            }
        }
    }
}

Write-Host "    Removed: $stage2" -ForegroundColor $(if ($stage2 -gt 0) {"Yellow"} else {"Green"})

# ══════════════════════════════════════════════════════════════════
#  SCORE DISTRIBUTION (for threshold tuning)
# ══════════════════════════════════════════════════════════════════

Write-Host ""
Write-Host "  Score distribution (all same-file pairs with score >= 0.20):" -ForegroundColor White
$buckets = @{ '0.20-0.29'=0; '0.30-0.39'=0; '0.40-0.49'=0; '0.50-0.59'=0; '0.60-0.69'=0; '0.70-0.79'=0; '0.80-0.89'=0; '0.90-1.00'=0 }
foreach ($p in $allPairs) {
    if     ($p.Score -ge 0.90) { $buckets['0.90-1.00']++ }
    elseif ($p.Score -ge 0.80) { $buckets['0.80-0.89']++ }
    elseif ($p.Score -ge 0.70) { $buckets['0.70-0.79']++ }
    elseif ($p.Score -ge 0.60) { $buckets['0.60-0.69']++ }
    elseif ($p.Score -ge 0.50) { $buckets['0.50-0.59']++ }
    elseif ($p.Score -ge 0.40) { $buckets['0.40-0.49']++ }
    elseif ($p.Score -ge 0.30) { $buckets['0.30-0.39']++ }
    else                        { $buckets['0.20-0.29']++ }
}
foreach ($b in ($buckets.GetEnumerator() | Sort-Object Name)) {
    $bar = "█" * [Math]::Min($b.Value, 50)
    $marker = if ([double]($b.Name.Split('-')[0]) -ge $CompositeThreshold) { " ← DEDUP" } else { "" }
    Write-Host "    $($b.Name): $($b.Value.ToString().PadLeft(4)) $bar$marker" -ForegroundColor Gray
}

# ══════════════════════════════════════════════════════════════════
#  RESULTS
# ══════════════════════════════════════════════════════════════════

$totalRemoved = $stage1 + $stage2
$surviving = ($allQuestions | Where-Object { $_.Decision -eq "KEEP" }).Count

Write-Host ""
Write-Host "  ╔══════════════════════════════════════════════════════╗" -ForegroundColor Magenta
Write-Host "  ║       📊 LOCAL DEDUP RESULTS                         ║" -ForegroundColor Magenta
Write-Host "  ╚══════════════════════════════════════════════════════╝" -ForegroundColor Magenta
Write-Host ""
Write-Host "  ┌──────────────────────┬─────────┐" -ForegroundColor White
Write-Host "  │ Stage                │ Removed │" -ForegroundColor White
Write-Host "  ├──────────────────────┼─────────┤" -ForegroundColor White
Write-Host "  │ 1. Exact hash        │ $('{0,7}' -f $stage1) │" -ForegroundColor White
Write-Host "  │ 2. Composite score   │ $('{0,7}' -f $stage2) │" -ForegroundColor White
Write-Host "  ├──────────────────────┼─────────┤" -ForegroundColor White
Write-Host "  │ TOTAL REMOVED        │ $('{0,7}' -f $totalRemoved) │" -ForegroundColor Yellow
Write-Host "  │ SURVIVING            │ $('{0,7}' -f $surviving) │" -ForegroundColor Green
Write-Host "  └──────────────────────┴─────────┘" -ForegroundColor White
Write-Host ""

# Per-monkey breakdown
Write-Host "  Per-monkey:" -ForegroundColor White
foreach ($m in ($allQuestions | Select-Object -ExpandProperty Monkey -Unique | Sort-Object)) {
    $total = ($allQuestions | Where-Object { $_.Monkey -eq $m }).Count
    $removed = ($allQuestions | Where-Object { $_.Monkey -eq $m -and $_.Decision -eq "REMOVED" }).Count
    $pct = if ($total -gt 0) { [Math]::Round(($removed/$total)*100,1) } else { 0 }
    Write-Host "    $($m.PadRight(14)) $($total.ToString().PadLeft(4)) → $($($total-$removed).ToString().PadLeft(4))  -$removed ($pct%)" -ForegroundColor Gray
}

# ══════════════════════════════════════════════════════════════════
#  OUTPUT
# ══════════════════════════════════════════════════════════════════

if (-not $OutputPath) { $OutputPath = Join-Path (Split-Path $BenchmarkPath -Parent) "dedup-local-results" }
if (-not (Test-Path $OutputPath)) { New-Item $OutputPath -ItemType Directory -Force | Out-Null }

# Save report
$report = [PSCustomObject]@{
    Timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    Method = "local-composite"
    CompositeThreshold = $CompositeThreshold
    Weights = "words=0.25, code-terms=0.45, bigrams=0.30"
    InputCount = $allQuestions.Count
    RemovedCount = $totalRemoved
    SurvivingCount = $surviving
    Decisions = $allQuestions | Where-Object { $_.Decision -eq "REMOVED" } |
        Select-Object Id, Monkey, Category, MergedInto, Reason, Score,
            @{N='Question';E={$_.Question.Substring(0,[Math]::Min(120,$_.Question.Length))}}
    TopPairs = $allPairs | Sort-Object Score -Descending | Select-Object -First 30
}
$reportPath = Join-Path $OutputPath "dedup-local-report.json"
$report | ConvertTo-Json -Depth 4 | Set-Content $reportPath -Encoding UTF8
Write-Host ""
Write-Host "  Report: $reportPath" -ForegroundColor Green

# Also save top pairs for manual review
$pairsPath = Join-Path $OutputPath "top-pairs.txt"
$pairLines = @("Top 30 similar pairs (for manual review):", "")
$allPairs | Sort-Object Score -Descending | Select-Object -First 30 | ForEach-Object {
    $pairLines += "Score: $($_.Score) | $($_.IdA) ($($_.MonkeyA)/$($_.CatA)) vs $($_.IdB) ($($_.MonkeyB)/$($_.CatB))"
    $pairLines += "  A: $($_.QA)..."
    $pairLines += "  B: $($_.QB)..."
    $pairLines += ""
}
Set-Content $pairsPath -Value ($pairLines -join "`n") -Encoding UTF8
Write-Host "  Top pairs: $pairsPath" -ForegroundColor Green

Write-Host ""
Write-Host "  Done. Reduction: $totalRemoved/$($allQuestions.Count) ($([Math]::Round(($totalRemoved/[Math]::Max(1,$allQuestions.Count))*100,1))%)" -ForegroundColor Magenta

return [PSCustomObject]@{
    InputCount=$allQuestions.Count; Removed=$totalRemoved; Surviving=$surviving
    Stage1=$stage1; Stage2=$stage2; ReportPath=$reportPath
}

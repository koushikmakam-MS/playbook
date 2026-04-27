<#
.SYNOPSIS
    Pester tests for DocHealthScorer.psm1 — Documentation health scoring
#>

BeforeAll {
    Import-Module "$PSScriptRoot\..\shared\DocHealthScorer.psm1" -Force
}

# ═══════════════════════════════════════════════════════════════
# FILTER FUNCTIONS (pure logic, no I/O)
# ═══════════════════════════════════════════════════════════════

Describe "Get-SourceFiles" {
    It "Returns .cs, .py, .js, .ts, .go files" {
        InModuleScope DocHealthScorer {
            $files = @('app.cs', 'main.py', 'index.js', 'app.ts', 'server.go')
            $result = Get-SourceFiles -Files $files
            $result.Count | Should -Be 5
        }
    }

    It "Excludes .md, .txt, .json, .xml" {
        InModuleScope DocHealthScorer {
            $files = @('README.md', 'notes.txt', 'config.json', 'data.xml')
            $result = Get-SourceFiles -Files $files
            @($result).Count | Should -Be 0
        }
    }

    It "Returns empty for no source files" {
        InModuleScope DocHealthScorer {
            $result = Get-SourceFiles -Files @('README.md', 'LICENSE', 'package.json')
            @($result).Count | Should -Be 0
        }
    }

    It "Handles mixed file list" {
        InModuleScope DocHealthScorer {
            $files = @('src/app.cs', 'README.md', 'lib/util.py', 'docs/guide.md', 'main.go', 'config.json')
            $result = Get-SourceFiles -Files $files
            $result.Count | Should -Be 3
            $result | Should -Contain 'src/app.cs'
            $result | Should -Contain 'lib/util.py'
            $result | Should -Contain 'main.go'
        }
    }

    It "Recognizes all supported extensions" {
        InModuleScope DocHealthScorer {
            $files = @('a.cs','b.py','c.js','d.ts','e.java','f.go','g.rb','h.php','i.kt','j.rs','k.swift','l.cpp','m.c','n.h')
            $result = Get-SourceFiles -Files $files
            $result.Count | Should -Be 14
        }
    }
}

Describe "Get-DocFiles" {
    It "Returns .md, .rst, .txt, .adoc files" {
        InModuleScope DocHealthScorer {
            $files = @('docs/guide.md', 'docs/api.rst', 'notes.txt', 'intro.adoc')
            $result = Get-DocFiles -Files $files
            $result.Count | Should -Be 4
        }
    }

    It "Excludes LICENSE.md and CHANGELOG.md" {
        InModuleScope DocHealthScorer {
            $files = @('LICENSE.md', 'CHANGELOG.md', 'CHANGES.md', 'HISTORY.md', 'docs/guide.md')
            $result = @(Get-DocFiles -Files $files)
            $result.Count | Should -Be 1
            $result | Should -Contain 'docs/guide.md'
        }
    }

    It "Excludes node_modules paths" {
        InModuleScope DocHealthScorer {
            $files = @('node_modules/pkg/README.md', 'docs/guide.md')
            $result = @(Get-DocFiles -Files $files)
            $result.Count | Should -Be 1
            $result | Should -Contain 'docs/guide.md'
        }
    }

    It "Returns empty for no doc files" {
        InModuleScope DocHealthScorer {
            $files = @('app.cs', 'main.py', 'server.go')
            $result = @(Get-DocFiles -Files $files)
            $result.Count | Should -Be 0
        }
    }
}

Describe "Get-TestFiles" {
    It "Matches common test file patterns" {
        InModuleScope DocHealthScorer {
            $files = @(
                'TestHelper.cs',
                'UserTests.cs',
                'app.test.js',
                'util.spec.ts',
                'helper_test.py',
                'model_spec.rb'
            )
            $result = Get-TestFiles -Files $files
            $result.Count | Should -Be 6
        }
    }

    It "Excludes non-test source files" {
        InModuleScope DocHealthScorer {
            $files = @('app.cs', 'main.py', 'server.go', 'index.js')
            $result = @(Get-TestFiles -Files $files)
            $result.Count | Should -Be 0
        }
    }

    It "Returns empty for no tests" {
        InModuleScope DocHealthScorer {
            $files = @('README.md', 'config.json', 'app.cs')
            $result = @(Get-TestFiles -Files $files)
            $result.Count | Should -Be 0
        }
    }

    It "Only matches files with source extensions" {
        InModuleScope DocHealthScorer {
            # test pattern in name but not a source extension
            $files = @('test-plan.md', 'spec.yaml')
            $result = @(Get-TestFiles -Files $files)
            $result.Count | Should -Be 0
        }
    }
}

# ═══════════════════════════════════════════════════════════════
# GRADE FUNCTION
# ═══════════════════════════════════════════════════════════════

Describe "Get-GradeFromScore" {
    It "Returns 'A' for score >= 90" {
        InModuleScope DocHealthScorer {
            Get-GradeFromScore -Score 95 | Should -Be 'A'
            Get-GradeFromScore -Score 90 | Should -Be 'A'
            Get-GradeFromScore -Score 100 | Should -Be 'A'
        }
    }

    It "Returns 'B' for 75-89" {
        InModuleScope DocHealthScorer {
            Get-GradeFromScore -Score 75 | Should -Be 'B'
            Get-GradeFromScore -Score 89 | Should -Be 'B'
        }
    }

    It "Returns 'C' for 60-74" {
        InModuleScope DocHealthScorer {
            Get-GradeFromScore -Score 60 | Should -Be 'C'
            Get-GradeFromScore -Score 74 | Should -Be 'C'
        }
    }

    It "Returns 'D' for 45-59" {
        InModuleScope DocHealthScorer {
            Get-GradeFromScore -Score 45 | Should -Be 'D'
            Get-GradeFromScore -Score 59 | Should -Be 'D'
        }
    }

    It "Returns 'F' for < 45" {
        InModuleScope DocHealthScorer {
            Get-GradeFromScore -Score 44 | Should -Be 'F'
            Get-GradeFromScore -Score 10 | Should -Be 'F'
        }
    }

    It "Handles edge case score 0" {
        InModuleScope DocHealthScorer {
            Get-GradeFromScore -Score 0 | Should -Be 'F'
        }
    }

    It "Handles custom Max parameter" {
        InModuleScope DocHealthScorer {
            # 45/50 = 90% → A
            Get-GradeFromScore -Score 45 -Max 50 | Should -Be 'A'
            # 30/50 = 60% → C
            Get-GradeFromScore -Score 30 -Max 50 | Should -Be 'C'
        }
    }
}

# ═══════════════════════════════════════════════════════════════
# FILE CONTENT
# ═══════════════════════════════════════════════════════════════

Describe "Get-FileContent" {
    BeforeAll {
        $script:testDir = Join-Path $TestDrive "filecontent"
        New-Item -ItemType Directory $script:testDir -Force | Out-Null
    }

    It "Reads existing file content" {
        InModuleScope DocHealthScorer -Parameters @{ testDir = $script:testDir } {
            $file = Join-Path $testDir "sample.txt"
            "Hello World" | Set-Content $file
            $result = Get-FileContent -RepoPath $testDir -RelPath "sample.txt"
            $result | Should -BeLike "*Hello World*"
        }
    }

    It "Returns null for non-existent file" {
        InModuleScope DocHealthScorer -Parameters @{ testDir = $script:testDir } {
            $result = Get-FileContent -RepoPath $testDir -RelPath "nonexistent.txt"
            $result | Should -BeNullOrEmpty
        }
    }

    It "Truncates at MaxBytes" {
        InModuleScope DocHealthScorer -Parameters @{ testDir = $script:testDir } {
            $file = Join-Path $testDir "big.txt"
            ('A' * 5000) | Set-Content $file -NoNewline
            $result = Get-FileContent -RepoPath $testDir -RelPath "big.txt" -MaxBytes 100
            $result.Length | Should -Be 100
        }
    }
}

# ═══════════════════════════════════════════════════════════════
# MEASURE FUNCTIONS (with temp repo structures)
# ═══════════════════════════════════════════════════════════════

Describe "Measure-CodeDocumentation" {
    BeforeAll {
        $script:testDir = Join-Path $TestDrive "codedoc"
        New-Item -ItemType Directory $script:testDir -Force | Out-Null
    }

    It "Gives points for README" {
        InModuleScope DocHealthScorer -Parameters @{ testDir = $script:testDir } {
            $readme = Join-Path $testDir "README.md"
            ('# My Project' + "`n" + ('Documentation content. ' * 100)) | Set-Content $readme
            $allFiles = @('README.md')
            $sourceFiles = @()
            $DocFiles = @()
            $result = Measure-CodeDocumentation -RepoPath $testDir -AllFiles $allFiles -SourceFiles $sourceFiles
            $result.Score | Should -BeGreaterThan 0
            $result.Max | Should -Be 20
            $result.Details['README'] | Should -BeLike "*Found*"
        }
    }

    It "Gives points for inline comments in source files" {
        InModuleScope DocHealthScorer -Parameters @{ testDir = $script:testDir } {
            $readme = Join-Path $testDir "README.md"
            ('# Project' + "`n" + ('Docs here. ' * 200)) | Set-Content $readme
            $csFile = Join-Path $testDir "Controller.cs"
            @"
using System;
/// <summary>Handles requests</summary>
[HttpGet]
public IActionResult Get() { return Ok(); }
"@ | Set-Content $csFile
            $allFiles = @('README.md', 'Controller.cs')
            $sourceFiles = @('Controller.cs')
            $DocFiles = @()
            $result = Measure-CodeDocumentation -RepoPath $testDir -AllFiles $allFiles -SourceFiles $sourceFiles
            $result.Score | Should -BeGreaterThan 5
        }
    }

    It "Returns max of 20" {
        InModuleScope DocHealthScorer -Parameters @{ testDir = $script:testDir } {
            $DocFiles = @()
            $result = Measure-CodeDocumentation -RepoPath $testDir -AllFiles @() -SourceFiles @()
            $result.Max | Should -Be 20
        }
    }
}

Describe "Measure-DocQuality" {
    BeforeAll {
        $script:testDir = Join-Path $TestDrive "docquality"
        New-Item -ItemType Directory $script:testDir -Force | Out-Null
    }

    It "Starts at max 20 and deducts for issues" {
        InModuleScope DocHealthScorer -Parameters @{ testDir = $script:testDir } {
            $docDir = Join-Path $testDir "docs"
            New-Item -ItemType Directory $docDir -Force | Out-Null
            $doc = Join-Path $docDir "guide.md"
            @"
# Guide
This is a clean doc with no dead refs.
## Section 1
Some content here.
"@ | Set-Content $doc
            $allFiles = @('docs/guide.md')
            $docFiles = @('docs/guide.md')
            $result = Measure-DocQuality -RepoPath $testDir -AllFiles $allFiles -DocFiles $docFiles
            $result.Max | Should -Be 20
            $result.Score | Should -BeGreaterThan 0
        }
    }

    It "Deducts for dead references" {
        InModuleScope DocHealthScorer -Parameters @{ testDir = $script:testDir } {
            $doc = Join-Path $testDir "deadrefs.md"
            @"
# Guide
See [setup](nonexistent-file.md) and [config](missing.yaml) for details.
Also check [api](phantom-api.md).
"@ | Set-Content $doc
            $allFiles = @('deadrefs.md')
            $docFiles = @('deadrefs.md')
            $result = Measure-DocQuality -RepoPath $testDir -AllFiles $allFiles -DocFiles $docFiles
            $result.Score | Should -BeLessThan 20
        }
    }
}

Describe "Measure-AIFriendliness" {
    BeforeAll {
        $script:testDir = Join-Path $TestDrive "aifriendly"
        New-Item -ItemType Directory $script:testDir -Force | Out-Null
    }

    It "Gives points for copilot-instructions.md" {
        InModuleScope DocHealthScorer -Parameters @{ testDir = $script:testDir } {
            $ghDir = Join-Path $testDir ".github"
            New-Item -ItemType Directory $ghDir -Force | Out-Null
            $ciFile = Join-Path $ghDir "copilot-instructions.md"
            "Instructions for copilot" | Set-Content $ciFile
            # Need at least one source file to avoid Get-Random -Count 0 error
            $srcFile = Join-Path $testDir "app.cs"
            "public class App { public int Id { get; set; } }" | Set-Content $srcFile
            $allFiles = @('.github/copilot-instructions.md', 'app.cs')
            $sourceFiles = @('app.cs')
            $result = Measure-AIFriendliness -RepoPath $testDir -AllFiles $allFiles -SourceFiles $sourceFiles -TargetAgents @('copilot')
            $result.Score | Should -BeGreaterThan 0
            $result.Max | Should -Be 25
            $result.Details['AgentConfigs'] | Should -BeLike "*copilot*"
        }
    }

    It "Gives points for architecture docs" {
        InModuleScope DocHealthScorer -Parameters @{ testDir = $script:testDir } {
            $archDir = Join-Path $testDir "docs"
            New-Item -ItemType Directory $archDir -Force | Out-Null
            "Architecture overview" | Set-Content (Join-Path $archDir "ARCHITECTURE.md")
            $srcFile = Join-Path $testDir "svc.cs"
            "public class Svc { }" | Set-Content $srcFile
            $allFiles = @('docs/ARCHITECTURE.md', 'svc.cs')
            $sourceFiles = @('svc.cs')
            $result = Measure-AIFriendliness -RepoPath $testDir -AllFiles $allFiles -SourceFiles $sourceFiles -TargetAgents @()
            $result.Details['ArchDocs'] | Should -BeLike "*architecture*"
        }
    }

    It "Gives points for conventional project layout" {
        InModuleScope DocHealthScorer -Parameters @{ testDir = $script:testDir } {
            $allFiles = @('src/app.cs', 'tests/apptest.cs', 'docs/guide.md', '.github/workflows/ci.yml')
            $sourceFiles = @('src/app.cs')
            $result = Measure-AIFriendliness -RepoPath $testDir -AllFiles $allFiles -SourceFiles $sourceFiles -TargetAgents @()
            $result.Details['ProjectLayout'] | Should -BeLike "*conventional*"
        }
    }
}

Describe "Measure-TestCoverage" {
    It "Scores based on test-to-source ratio" {
        InModuleScope DocHealthScorer {
            $allFiles = @('src/User.cs', 'src/Order.cs', 'tests/UserTests.cs', 'tests/OrderTests.cs')
            $sourceFiles = @('src/User.cs', 'src/Order.cs', 'tests/UserTests.cs', 'tests/OrderTests.cs')
            $testFiles = @('tests/UserTests.cs', 'tests/OrderTests.cs')
            $result = Measure-TestCoverage -RepoPath "C:\fake" -AllFiles $allFiles -SourceFiles $sourceFiles -TestFiles $testFiles
            $result.Max | Should -Be 15
            $result.Score | Should -BeGreaterThan 0
        }
    }

    It "Returns 0 pairing score when no tests exist" {
        InModuleScope DocHealthScorer {
            $allFiles = @('src/User.cs', 'src/Order.cs')
            $sourceFiles = @('src/User.cs', 'src/Order.cs')
            $testFiles = @()
            $result = Measure-TestCoverage -RepoPath "C:\fake" -AllFiles $allFiles -SourceFiles $sourceFiles -TestFiles $testFiles
            $result.Score | Should -Be 0
        }
    }

    It "Gives infrastructure points for CI config" {
        InModuleScope DocHealthScorer {
            $allFiles = @('src/app.cs', 'tests/AppTests.cs', '.github/workflows/ci.yml')
            $sourceFiles = @('src/app.cs', 'tests/AppTests.cs')
            $testFiles = @('tests/AppTests.cs')
            $result = Measure-TestCoverage -RepoPath "C:\fake" -AllFiles $allFiles -SourceFiles $sourceFiles -TestFiles $testFiles
            $result.Details['TestInfra'] | Should -BeLike "*CI*"
            $result.Score | Should -BeGreaterThan 0
        }
    }
}

Describe "Measure-RiskSignals" {
    BeforeAll {
        $script:testDir = Join-Path $TestDrive "risksignals"
        New-Item -ItemType Directory $script:testDir -Force | Out-Null
    }

    It "Starts at 20 for clean code" {
        InModuleScope DocHealthScorer -Parameters @{ testDir = $script:testDir } {
            $cleanFile = Join-Path $testDir "clean.cs"
            @"
public class Clean {
    public void DoWork() {
        Console.WriteLine("Working");
    }
}
"@ | Set-Content $cleanFile
            $allFiles = @('clean.cs')
            $sourceFiles = @('clean.cs')
            $result = Measure-RiskSignals -RepoPath $testDir -AllFiles $allFiles -SourceFiles $sourceFiles
            $result.Max | Should -Be 20
            $result.Score | Should -Be 20
        }
    }

    It "Deducts for TODO/FIXME/HACK markers" {
        InModuleScope DocHealthScorer -Parameters @{ testDir = $script:testDir } {
            $todoFile = Join-Path $testDir "messy.cs"
            @"
public class Messy {
    // TODO: fix this later
    // FIXME: broken logic
    // HACK: temporary workaround
    // XXX: danger zone
    // WORKAROUND: for upstream bug
    public void DoWork() {
        // TODO: another one
        // TODO: and another
        // HACK: yet another hack
        // FIXME: more broken stuff
        // TODO: tenth marker
    }
}
"@ | Set-Content $todoFile
            $allFiles = @('messy.cs')
            $sourceFiles = @('messy.cs')
            $result = Measure-RiskSignals -RepoPath $testDir -AllFiles $allFiles -SourceFiles $sourceFiles
            $result.Score | Should -BeLessThan 20
            $result.Details['TodoDensity'] | Should -BeLike "*TODO*"
        }
    }

    It "Deducts for empty catch blocks" {
        InModuleScope DocHealthScorer -Parameters @{ testDir = $script:testDir } {
            $catchFile = Join-Path $testDir "catches.cs"
            @"
public class Bad {
    public void Method() {
        try { DoWork(); } catch (Exception ex) { }
        try { DoMore(); } catch { }
    }
}
"@ | Set-Content $catchFile
            $allFiles = @('catches.cs')
            $sourceFiles = @('catches.cs')
            $result = Measure-RiskSignals -RepoPath $testDir -AllFiles $allFiles -SourceFiles $sourceFiles
            $result.Score | Should -BeLessThan 20
            $result.Details['EmptyCatches'] | Should -BeLike "*empty catch*"
        }
    }

    It "Deducts for hardcoded secrets" {
        InModuleScope DocHealthScorer -Parameters @{ testDir = $script:testDir } {
            $secretFile = Join-Path $testDir "config.cs"
            @"
public class Config {
    private string password = "SuperSecret123!";
    private string apikey = "abcdef1234567890";
}
"@ | Set-Content $secretFile
            $allFiles = @('config.cs')
            $sourceFiles = @('config.cs')
            $result = Measure-RiskSignals -RepoPath $testDir -AllFiles $allFiles -SourceFiles $sourceFiles
            $result.Score | Should -BeLessThan 20
            $result.Details['HardcodedSecrets'] | Should -BeLike "*secret*"
        }
    }
}

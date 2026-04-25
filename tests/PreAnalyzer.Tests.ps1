<#
.SYNOPSIS
    Pester tests for PreAnalyzer.psm1 — Code structure extraction
#>

BeforeAll {
    Import-Module "$PSScriptRoot\..\shared\PreAnalyzer.psm1" -Force
}

Describe "Get-CodeStructure" {
    BeforeAll {
        $script:testDir = Join-Path $env:TEMP "pester-preanalyzer-$(Get-Random)"
        New-Item -ItemType Directory $script:testDir -Force | Out-Null
    }
    AfterAll {
        Remove-Item $script:testDir -Recurse -Force -ErrorAction SilentlyContinue
    }

    Context "C# files" {
        BeforeAll {
            $script:csFile = Join-Path $script:testDir "TestController.cs"
            @"
using System;
using Microsoft.AspNetCore.Mvc;

namespace MyApp.Controllers
{
    [ApiController]
    [Route("api/[controller]")]
    public class TestController : ControllerBase
    {
        [HttpGet("{id}")]
        public IActionResult GetItem(int id)
        {
            if (id <= 0) return BadRequest();
            return Ok();
        }

        [HttpPost]
        public async Task<IActionResult> CreateItem(ItemDto dto)
        {
            if (dto == null) throw new ArgumentNullException();
            for (int i = 0; i < dto.Tags.Count; i++)
            {
                if (string.IsNullOrEmpty(dto.Tags[i]))
                {
                    continue;
                }
            }
            return Created();
        }

        private void ValidateInternal()
        {
            try { /* validate */ }
            catch (Exception ex) { throw; }
        }
    }
}
"@ | Set-Content $script:csFile
        }

        It "Detects language as csharp" {
            $result = Get-CodeStructure -FilePath $script:csFile
            $result.Language | Should -Be "csharp"
        }

        It "Finds the class" {
            $result = Get-CodeStructure -FilePath $script:csFile
            $result.Classes | Should -Contain "TestController"
        }

        It "Finds methods" {
            $result = Get-CodeStructure -FilePath $script:csFile
            $result.Functions.Count | Should -BeGreaterOrEqual 3
            ($result.Functions | ForEach-Object { $_.Name }) | Should -Contain "GetItem"
            ($result.Functions | ForEach-Object { $_.Name }) | Should -Contain "CreateItem"
        }

        It "Finds using statements" {
            $result = Get-CodeStructure -FilePath $script:csFile
            $result.Imports | Should -Contain "System"
            $result.Imports | Should -Contain "Microsoft.AspNetCore.Mvc"
        }

        It "Finds route attributes" {
            $result = Get-CodeStructure -FilePath $script:csFile
            $result.Routes.Count | Should -BeGreaterOrEqual 1
        }

        It "Calculates complexity" {
            $result = Get-CodeStructure -FilePath $script:csFile
            $result.Complexity.BranchCount | Should -BeGreaterThan 0
            $result.Complexity.MaxNesting | Should -BeGreaterThan 0
            $result.Complexity.Score | Should -BeGreaterThan 0
        }

        It "Counts lines" {
            $result = Get-CodeStructure -FilePath $script:csFile
            $result.LineCount | Should -BeGreaterThan 10
        }
    }

    Context "Python files" {
        BeforeAll {
            $script:pyFile = Join-Path $script:testDir "app.py"
            @"
from flask import Flask, jsonify
import os

app = Flask(__name__)

class UserService:
    def get_user(self, user_id):
        if not user_id:
            return None
        return {"id": user_id}

@app.get('/users/<int:id>')
def get_user(id):
    return jsonify({"id": id})

@app.post('/users')
def create_user():
    return jsonify({"status": "created"}), 201
"@ | Set-Content $script:pyFile
        }

        It "Detects language as python" {
            $result = Get-CodeStructure -FilePath $script:pyFile
            $result.Language | Should -Be "python"
        }

        It "Finds classes and functions" {
            $result = Get-CodeStructure -FilePath $script:pyFile
            $result.Classes | Should -Contain "UserService"
            $result.Functions.Count | Should -BeGreaterOrEqual 2
        }

        It "Finds imports" {
            $result = Get-CodeStructure -FilePath $script:pyFile
            $result.Imports.Count | Should -BeGreaterOrEqual 2
        }

        It "Finds route decorators" {
            $result = Get-CodeStructure -FilePath $script:pyFile
            $result.Routes.Count | Should -BeGreaterOrEqual 1
        }
    }

    Context "Go files" {
        BeforeAll {
            $script:goFile = Join-Path $script:testDir "main.go"
            @"
package main

import (
    "fmt"
    "net/http"
    "github.com/gorilla/mux"
)

func GetUser(w http.ResponseWriter, r *http.Request) {
    fmt.Fprintln(w, "user")
}

func (s *Server) HandleHealth(w http.ResponseWriter, r *http.Request) {
    w.WriteHeader(http.StatusOK)
}

func main() {
    r := mux.NewRouter()
    r.HandleFunc("/users/{id}", GetUser)
    http.ListenAndServe(":8080", r)
}
"@ | Set-Content $script:goFile
        }

        It "Detects language as go" {
            $result = Get-CodeStructure -FilePath $script:goFile
            $result.Language | Should -Be "go"
        }

        It "Finds functions including receiver methods" {
            $result = Get-CodeStructure -FilePath $script:goFile
            ($result.Functions | ForEach-Object { $_.Name }) | Should -Contain "GetUser"
            ($result.Functions | ForEach-Object { $_.Name }) | Should -Contain "HandleHealth"
            ($result.Functions | ForEach-Object { $_.Name }) | Should -Contain "main"
        }

        It "Finds imports" {
            $result = Get-CodeStructure -FilePath $script:goFile
            $result.Imports | Should -Contain "github.com/gorilla/mux"
        }

        It "Finds routes" {
            $result = Get-CodeStructure -FilePath $script:goFile
            $result.Routes.Count | Should -BeGreaterOrEqual 1
        }
    }

    Context "Edge cases" {
        It "Returns null for non-existent file" {
            $result = Get-CodeStructure -FilePath "C:\nonexistent\file.cs"
            $result | Should -BeNullOrEmpty
        }

        It "Handles empty file" {
            $emptyFile = Join-Path $script:testDir "empty.cs"
            "" | Set-Content $emptyFile
            $result = Get-CodeStructure -FilePath $emptyFile
            $result | Should -Not -BeNullOrEmpty
            $result.Functions.Count | Should -Be 0
        }

        It "Auto-detects language from extension" {
            $tsFile = Join-Path $script:testDir "index.ts"
            "export function hello() {}" | Set-Content $tsFile
            $result = Get-CodeStructure -FilePath $tsFile
            $result.Language | Should -Be "typescript"
        }

        It "Returns unknown for unrecognized extension" {
            $txtFile = Join-Path $script:testDir "notes.txt"
            "some text" | Set-Content $txtFile
            $result = Get-CodeStructure -FilePath $txtFile
            $result.Language | Should -Be "unknown"
        }
    }
}

Describe "Get-PreAnalysisSummary" {
    BeforeAll {
        $script:testDir = Join-Path $env:TEMP "pester-summary-$(Get-Random)"
        New-Item -ItemType Directory $script:testDir -Force | Out-Null

        # Create two test files with different complexity
        $script:simpleFile = Join-Path $script:testDir "Simple.cs"
        @"
public class Simple {
    public void DoThing() { return; }
}
"@ | Set-Content $script:simpleFile

        $script:complexFile = Join-Path $script:testDir "Complex.cs"
        @"
public class Complex {
    public void Method1() { if (true) { for (int i=0; i<10; i++) { if (i > 5) { try { } catch { } } } } }
    public void Method2() { switch(x) { case 1: break; case 2: break; } }
    public void Method3() { while(true) { foreach(var i in list) { if (i != null) { } } } }
}
"@ | Set-Content $script:complexFile
    }
    AfterAll {
        Remove-Item $script:testDir -Recurse -Force -ErrorAction SilentlyContinue
    }

    It "Returns results sorted by complexity descending" {
        $eps = @(
            @{ Path=$script:simpleFile; RelPath="Simple.cs"; Language="csharp" },
            @{ Path=$script:complexFile; RelPath="Complex.cs"; Language="csharp" }
        )
        $result = Get-PreAnalysisSummary -EntryPoints $eps -WorkingDirectory $script:testDir

        $result.Count | Should -Be 2
        $result[0].Complexity | Should -BeGreaterThan $result[1].Complexity
    }

    It "Returns results with summary fields" {
        $eps = @(
            @{ Path=$script:complexFile; RelPath="Complex.cs"; Language="csharp" }
        )
        $result = @(Get-PreAnalysisSummary -EntryPoints $eps -WorkingDirectory $script:testDir)
        $result.Count | Should -Be 1
        $result[0].Language | Should -Be "csharp"
        $result[0].Complexity | Should -BeGreaterThan 0
        $result[0].Functions | Should -BeGreaterThan 0
    }
}

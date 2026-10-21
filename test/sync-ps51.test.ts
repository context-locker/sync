// sync.ps1 runs in Windows PowerShell 5.1 as well as PowerShell 7. These
// tests run here only, so PSScriptAnalyzer checks its syntax and commands
// against 5.1 on Windows: they run when pwsh and PSScriptAnalyzer are both
// installed, and are skipped otherwise.
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { describe, it } from "node:test";
import { fileURLToPath } from "node:url";

const PS_SCRIPT = fileURLToPath(
  new URL("../scripts/sync.ps1", import.meta.url),
);

// Windows PowerShell 5.1 on Windows 10 (1809) with .NET Framework 4.8
const PROFILE =
  "win-48_x64_10.0.17763.0_5.1.17763.316_x64_4.0.30319.42000_framework";

function analyzerReady(): boolean {
  if (spawnSync("sh", ["-c", "command -v pwsh"]).status !== 0) return false;
  const found = spawnSync(
    "pwsh",
    [
      "-NoProfile",
      "-NonInteractive",
      "-Command",
      "if (Get-Module -ListAvailable PSScriptAnalyzer) { exit 0 } else { exit 1 }",
    ],
    { env: { ...process.env, POWERSHELL_TELEMETRY_OPTOUT: "1" } },
  );
  return found.status === 0;
}

describe(
  "sync.ps1 in Windows PowerShell 5.1",
  { skip: !analyzerReady() && "pwsh or PSScriptAnalyzer isn't installed" },
  () => {
    it("uses only syntax and commands 5.1 has", () => {
      const check = `
        $settings = @{
          IncludeRules = @('PSUseCompatibleSyntax', 'PSUseCompatibleCommands')
          Rules = @{
            PSUseCompatibleSyntax = @{ Enable = $true; TargetVersions = @('5.1') }
            PSUseCompatibleCommands = @{ Enable = $true; TargetProfiles = @('${PROFILE}') }
          }
        }
        $found = @(Invoke-ScriptAnalyzer -Path $env:CHECKED_SCRIPT -Settings $settings)
        foreach ($finding in $found) { "$($finding.Line) $($finding.RuleName): $($finding.Message)" }
      `;
      const result = spawnSync(
        "pwsh",
        ["-NoProfile", "-NonInteractive", "-Command", check],
        {
          encoding: "utf8",
          env: {
            ...process.env,
            CHECKED_SCRIPT: PS_SCRIPT,
            POWERSHELL_TELEMETRY_OPTOUT: "1",
          },
          timeout: 300_000,
        },
      );
      assert.equal(result.status, 0, result.stderr);
      assert.equal(result.stdout.trim(), "", "PSScriptAnalyzer's findings");
    });
  },
);

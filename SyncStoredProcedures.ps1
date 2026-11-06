
param(
    [string]$SourceServer = "SERVER_A",
    [string]$SourceDatabase = "DatabaseA",

    [string]$TargetServer = "SERVER_B",
    [string]$TargetDatabase = "DatabaseB",

    [string]$SourceUser,
    [string]$SourcePassword,

    [string]$TargetUser,
    [string]$TargetPassword,

    [bool]$DryRun = $true
)

$ErrorActionPreference = "Stop"

$logFile = ".\SyncStoredProcedures.log"

# Connection (Integrated Security by default; SQL Auth when user/password provided)
function New-Connection($server, $database, $user, $password) {

    if ([string]::IsNullOrWhiteSpace($user)) {
        $auth = "Integrated Security=True;"
    }
    else {
        $auth = "User ID=$user;Password=$password;"
    }

    $connectionString = @"
Server=$server;
Database=$database;
$auth
Encrypt=True;
TrustServerCertificate=True;
Application Name=SP-Synchronizer;
"@ -replace "`r?`n", ""

    return New-Object System.Data.SqlClient.SqlConnection(
        $connectionString
    )
}

function Get-StoredProcedures($connection) {

    $query = @"
SELECT
    s.name AS SchemaName,
    p.name AS ProcedureName,
    m.definition AS Definition,
    m.uses_ansi_nulls AS UsesAnsiNulls,
    m.uses_quoted_identifier AS UsesQuotedIdentifier
FROM sys.procedures p
INNER JOIN sys.schemas s
    ON p.schema_id = s.schema_id
INNER JOIN sys.sql_modules m
    ON p.object_id = m.object_id
WHERE p.is_ms_shipped = 0
  AND p.type = 'P';
"@

    $command = $connection.CreateCommand()
    $command.CommandText = $query

    $reader = $command.ExecuteReader()

    $procedures = @{}

    while ($reader.Read()) {

        $key = "$($reader["SchemaName"]).$($reader["ProcedureName"])"

        $procedures[$key] = @{
            Schema = $reader["SchemaName"].ToString()
            Name = $reader["ProcedureName"].ToString()
            Definition = $reader["Definition"].ToString()
            AnsiNulls = [bool]$reader["UsesAnsiNulls"]
            QuotedIdentifier = [bool]$reader["UsesQuotedIdentifier"]
        }
    }

    $reader.Close()

    return $procedures
}

function Normalize-Definition($definition) {

    return ($definition -replace "`r`n", "`n").Trim()
}

function Convert-ToCreateOrAlter($definition) {

    $pattern = '(?im)^(\s*)CREATE\s+(?:(?:OR\s+ALTER)\s+)?(?:PROC|PROCEDURE)\b'

    if ($definition -notmatch $pattern) {
        throw "Cannot identify CREATE PROCEDURE statement."
    }

    return [regex]::Replace(
        $definition,
        $pattern,
        '${1}CREATE OR ALTER PROCEDURE',
        [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
    )
}

function Execute-SqlBatches($connection, $script) {

    # GO is a client-side batch separator.
    $batches = [regex]::Split(
        $script,
        '(?im)^\s*GO\s*(?:--.*)?$'
    )

    foreach ($batch in $batches) {

        if ([string]::IsNullOrWhiteSpace($batch)) {
            continue
        }

        $command = $connection.CreateCommand()
        $command.CommandText = $batch
        $command.CommandTimeout = 120

        [void]$command.ExecuteNonQuery()
        $command.Dispose()
    }
}

$sourceConnection = New-Connection $SourceServer $SourceDatabase $SourceUser $SourcePassword
$targetConnection = New-Connection $TargetServer $TargetDatabase $TargetUser $TargetPassword

try {

    $sourceConnection.Open()
    $targetConnection.Open()

    Write-Host "Reading source procedures..."

    $sourceProcedures = Get-StoredProcedures $sourceConnection

    Write-Host "Reading target procedures..."

    $targetProcedures = Get-StoredProcedures $targetConnection

    Write-Host "Comparing procedures..."

    foreach ($key in $sourceProcedures.Keys) {

        $source = $sourceProcedures[$key]

        $target = $targetProcedures[$key]

        $action = ""

        if ($null -eq $target) {
            $action = "CREATE"
        }
        elseif (
            (Normalize-Definition $source.Definition) -ne
            (Normalize-Definition $target.Definition) -or
            $source.AnsiNulls -ne $target.AnsiNulls -or
            $source.QuotedIdentifier -ne $target.QuotedIdentifier
        ) {
            $action = "ALTER"
        }
        else {
            continue
        }

        $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"

        Write-Host "$action : $key"

        Add-Content $logFile "$timestamp | $action | $key"

        if ([string]::IsNullOrWhiteSpace($source.Definition)) {
            Write-Warning "Encrypted or unavailable definition: $key"
            continue
        }

        $ansi = if ($source.AnsiNulls) { "ON" } else { "OFF" }
        $quoted = if ($source.QuotedIdentifier) { "ON" } else { "OFF" }

        $procedureScript = Convert-ToCreateOrAlter $source.Definition

        $script = @"
SET ANSI_NULLS $ansi
GO
SET QUOTED_IDENTIFIER $quoted
GO
$procedureScript
GO
"@

        if ($DryRun) {

            Write-Host "[DRY RUN] No changes applied."

            $script | Out-File -LiteralPath ".\SP_$($source.Schema)_$($source.Name).sql" -Encoding utf8

            continue
        }

        try {

            Execute-SqlBatches $targetConnection $script

            Add-Content $logFile "$timestamp | SUCCESS | $key"

        }
        catch {

            Write-Host "ERROR updating $key : $_" -ForegroundColor Red

            Add-Content $logFile "$timestamp | ERROR | $key | $_"
        }
    }

    Write-Host "Synchronization process completed."

}
finally {

    if ($sourceConnection.State -eq "Open") {
        $sourceConnection.Close()
    }

    if ($targetConnection.State -eq "Open") {
        $targetConnection.Close()
    }
}

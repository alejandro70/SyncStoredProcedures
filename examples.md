# Autenticación integrada (Windows)
.\SyncStoredProcedures.ps1 -SourceServer "SQLPRE07\AUTONET" -SourceDatabase "Persona" -TargetServer "SQLDEVACELAE01\ACELATCOR01" -TargetDatabase "Persona" -DryRun $true

# Autenticación SQL (usuario/clave)
.\SyncStoredProcedures.ps1 -SourceServer "SQLPRE07\AUTONET" -SourceDatabase "Persona" -SourceUser "usuario" -SourcePassword "clave" -TargetServer "SQLDEVACELAE01\ACELATCOR01" -TargetDatabase "Persona" -TargetUser "usuario" -TargetPassword "clave" -DryRun $true
function Find-PCManager {
    [CmdletBinding()]
    param()

    $candidates = @()

    $pf = ${env:ProgramFiles}
    if ($pf) {
        $candidates += Join-Path $pf 'HONOR\PCManager'
        $candidates += Join-Path $pf 'HONOR\HONOR PC Manager'
    }

    $pf86 = ${env:ProgramFiles(x86)}
    if ($pf86) {
        $candidates += Join-Path $pf86 'HONOR\PCManager'
        $candidates += Join-Path $pf86 'HONOR\HONOR PC Manager'
    }

    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate) {
            return $candidate
        }
    }

    return $null
}

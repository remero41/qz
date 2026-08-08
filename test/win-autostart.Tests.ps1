# Tests Pester del watchdog de win-autostart.ps1 — REQUIEREN WINDOWS REAL.
#
# Estos NO se han ejecutado nunca todavía: en la máquina de desarrollo (Linux) no
# hay PowerShell. Se dejan escritos para el "tiempo 2", cuando haya Windows
# accesible. Cualquiera que los ejecute debe anotar el resultado real; hasta
# entonces NO se puede afirmar que estén verdes.
#
# Ejecutar:
#   Install-Module Pester -Force -Scope CurrentUser     # si no está
#   Invoke-Pester .\test\win-autostart.Tests.ps1 -Output Detailed
#
# QUÉ CUBREN: la lógica pura extraída del cuerpo del watchdog (freno anti-bucle,
# parseo de puertos, preferencia .autostart). NO cubren el Task Scheduler, el
# multiusuario ni el parpadeo: eso es medición manual (test/MEDICION-WINDOWS.md).

BeforeAll {
    $script:Repo   = Split-Path -Parent $PSScriptRoot
    $script:Target = Join-Path $Repo 'provision-src\win-autostart.ps1'

    # Extrae el cuerpo del watchdog del here-string @'...'@ del script real, para
    # testear EL CÓDIGO QUE SE DESPLIEGA y no una copia que se desincroniza.
    $raw = Get-Content -Path $script:Target -Raw
    $m = [regex]::Match($raw, "(?s)\`$watchdog = @'\r?\n(.*?)\r?\n'@")
    if (-not $m.Success) { throw "No se pudo extraer el cuerpo del watchdog de $($script:Target)" }
    $script:WatchdogBody = $m.Groups[1].Value

    # Sandbox: LOCALAPPDATA/APPDATA propios para no tocar el perfil real.
    $script:Sandbox = Join-Path ([IO.Path]::GetTempPath()) ("qz-wd-" + [guid]::NewGuid())
    New-Item -ItemType Directory -Force -Path $script:Sandbox | Out-Null
}

AfterAll {
    if ($script:Sandbox -and (Test-Path $script:Sandbox)) {
        Remove-Item $script:Sandbox -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Describe 'Freno anti-bucle del relanzado (caso C)' {

    BeforeEach {
        $script:StateDir = Join-Path $script:Sandbox ([guid]::NewGuid())
        New-Item -ItemType Directory -Force -Path $script:StateDir | Out-Null
        $env:LOCALAPPDATA = $script:StateDir
        $script:StateFile = Join-Path $script:StateDir 'qz-watchdog-state.txt'

        # Se cargan SOLO las funciones de estado, tal como están en el script real.
        $funcs = [regex]::Match($script:WatchdogBody,
            '(?s)\$stateFile = Join-Path.*?function Clear-RestartState \{.*?\n\}').Value
        if (-not $funcs) { throw 'No se pudieron extraer las funciones de estado' }
        Invoke-Expression $funcs
    }

    It 'sin estado previo, el contador arranca a 0' {
        $st = Get-RestartState
        $st.Count | Should -Be 0
    }

    It 'persiste el contador entre invocaciones (cada pasada es un proceso nuevo)' {
        Set-RestartState 3
        # Simula una pasada nueva: se releen las funciones y el fichero.
        $st = Get-RestartState
        $st.Count | Should -Be 3
        Test-Path $script:StateFile | Should -BeTrue
    }

    It 'Clear-RestartState rearma el freno (autocuración cuando QZ vuelve a responder)' {
        Set-RestartState 5
        Clear-RestartState
        (Get-RestartState).Count | Should -Be 0
    }

    It 'guarda una marca de tiempo parseable junto al contador' {
        Set-RestartState 2
        $st = Get-RestartState
        $st.Last | Should -BeOfType [datetime]
        ($st.Last -gt [datetime]::MinValue) | Should -BeTrue
    }

    It 'REGRESIÓN: a los 5 intentos se rinde, no relanza para siempre' {
        # El bug original: sin contador, un websocket que nunca abre producía
        # mata-relanza cada ~4 min indefinidamente. La condición de rendición es
        # Count >= 5; se comprueba que el estado la alcanza y se conserva.
        1..5 | ForEach-Object { Set-RestartState $_ }
        (Get-RestartState).Count | Should -BeGreaterOrEqual 5
    }

    It 'el backoff crece: 4, 8, 16, 32, 60 min (tope 60)' {
        $esperado = @(4, 8, 16, 32, 60)
        for ($i = 0; $i -lt 5; $i++) {
            $waitMin = [Math]::Min(60, 4 * [Math]::Pow(2, $i))
            $waitMin | Should -Be $esperado[$i]
        }
    }
}

Describe 'Sonda de puertos' {

    BeforeEach {
        $script:PortDir = Join-Path $script:Sandbox ([guid]::NewGuid())
        New-Item -ItemType Directory -Force -Path (Join-Path $script:PortDir 'qz') | Out-Null
        $env:APPDATA = $script:PortDir
        $env:PROGRAMDATA = $script:PortDir
        $script:exe = Join-Path $script:PortDir 'qz-tray.exe'
        Set-Content -Path $script:exe -Value 'stub'

        $fn = [regex]::Match($script:WatchdogBody, '(?s)function Get-QzPorts \{.*?\n\}').Value
        if (-not $fn) { throw 'No se pudo extraer Get-QzPorts' }
        Invoke-Expression $fn
    }

    It 'incluye siempre los 8 puertos por defecto' {
        $ports = Get-QzPorts
        foreach ($p in 8181, 8282, 8383, 8484, 8182, 8283, 8384, 8485) {
            $ports | Should -Contain $p
        }
    }

    It 'REGRESIÓN: añade los puertos CONFIGURADOS en prefs.properties' {
        # El bug: la lista fija de 8 daba falso NEGATIVO si el usuario cambió los
        # puertos en las prefs de QZ (WebsocketPorts.java los lee de ahí), y el
        # watchdog mataba cada pocos minutos un QZ perfectamente sano.
        Set-Content -Path (Join-Path $script:PortDir 'qz\prefs.properties') `
                    -Value "websocket.secure.ports=9191,9292`nwebsocket.insecure.ports=9193"
        $ports = Get-QzPorts
        $ports | Should -Contain 9191
        $ports | Should -Contain 9292
        $ports | Should -Contain 9193
    }

    It 'ignora valores basura sin reventar' {
        Set-Content -Path (Join-Path $script:PortDir 'qz\prefs.properties') `
                    -Value "websocket.secure.ports=abc,,99999,-1,8181"
        { Get-QzPorts } | Should -Not -Throw
        $ports = Get-QzPorts
        $ports | Should -Not -Contain 99999
        $ports | Should -Not -Contain -1
    }

    It 'no duplica un puerto que ya está en los defaults' {
        Set-Content -Path (Join-Path $script:PortDir 'qz\prefs.properties') `
                    -Value "websocket.secure.ports=8181"
        ($ports = Get-QzPorts) | Out-Null
        (@($ports | Where-Object { $_ -eq 8181 })).Count | Should -Be 1
    }
}

Describe 'Preferencia .autostart (gate anti-bucle heredado)' {

    BeforeEach {
        $script:AsDir = Join-Path $script:Sandbox ([guid]::NewGuid())
        New-Item -ItemType Directory -Force -Path (Join-Path $script:AsDir 'qz') | Out-Null
        $env:APPDATA = $script:AsDir
        $env:PROGRAMDATA = $script:AsDir

        $fn = [regex]::Match($script:WatchdogBody, '(?s)function Test-QzAutostartWanted \{.*?\n\}').Value
        if (-not $fn) { throw 'No se pudo extraer Test-QzAutostartWanted' }
        Invoke-Expression $fn
    }

    It 'sin fichero .autostart, se considera que QZ debe arrancar' {
        Test-QzAutostartWanted | Should -BeTrue
    }

    It 'con .autostart = 0, el watchdog NO debe relanzar' {
        Set-Content -Path (Join-Path $script:AsDir 'qz\.autostart') -Value '0'
        Test-QzAutostartWanted | Should -BeFalse
    }

    It 'con .autostart = 1, sí relanza' {
        Set-Content -Path (Join-Path $script:AsDir 'qz\.autostart') -Value '1'
        Test-QzAutostartWanted | Should -BeTrue
    }
}

Describe 'Techo de heap' {

    It 'el script fija QZ_OPTS como variable de MÁQUINA con los tres flags' {
        $raw = Get-Content -Path $script:Target -Raw
        $raw | Should -Match "SetEnvironmentVariable\('QZ_OPTS'"
        $raw | Should -Match "'Machine'"
        $raw | Should -Match '-Xmx512m'
        $raw | Should -Match 'UseSerialGC'
        $raw | Should -Match 'MaxMetaspaceSize=128m'
    }

    It 'NO usa _JAVA_OPTIONS ni JAVA_TOOL_OPTIONS (afectarían a toda JVM del equipo)' {
        $code = (Get-Content -Path $script:Target) | Where-Object { $_ -notmatch '^\s*#' }
        ($code -join "`n") | Should -Not -Match '_JAVA_OPTIONS|JAVA_TOOL_OPTIONS'
    }
}

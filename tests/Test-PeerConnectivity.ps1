Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '../scripts/FiberWindows.psm1') -Force

& (Get-Module FiberWindows) {
    function script:Invoke-RestMethod {
        param($Uri, $Method, $Headers, $Body, $TimeoutSec, [switch]$UseBasicParsing)
        $request = $Body | ConvertFrom-Json
        switch ($request.method) {
            'list_peers' {
                $script:polls++
                $peers = if ($script:polls -ge $script:readyAfter) {
                    @([pscustomobject]@{ pubkey = '02AABB' })
                } else { @([pscustomobject]@{ pubkey = '02unrelated' }) }
                return [pscustomobject]@{ result = [pscustomobject]@{ peers = $peers } }
            }
            'connect_peer' {
                $script:dials++
                $script:lastDial = $request.params[0]
                return [pscustomobject]@{ result = $null }
            }
            default { throw "Unexpected RPC in peer connectivity test: $($request.method)" }
        }
    }
    try {
        $settings = [pscustomobject]@{
            rpcUrl = 'http://fixture.invalid'
            peer = [pscustomobject]@{ pubkey = '02aabb'; address = '/ip4/127.0.0.1/tcp/8228' }
        }
        $script:polls = 0; $script:dials = 0; $script:readyAfter = 1
        Wait-FiberPeerConnected -Settings $settings -TimeoutSeconds 5
        if ($script:dials -ne 0) { throw 'An already connected peer must not be redialed' }

        $script:polls = 0; $script:dials = 0; $script:readyAfter = 3
        Wait-FiberPeerConnected -Settings $settings -TimeoutSeconds 10
        if ($script:dials -ne 2 -or $script:lastDial.address -ne $settings.peer.address -or -not $script:lastDial.save) {
            throw 'Dial acceptance must not count as a connection to the expected identity'
        }

        $settings.peer.address = ''
        $script:polls = 0; $script:dials = 0; $script:readyAfter = 2
        Wait-FiberPeerConnected -Settings $settings -TimeoutSeconds 5
        if ($script:lastDial.pubkey -ne '02aabb' -or $script:lastDial.addr_type -ne 'tcp') {
            throw 'Peers without a configured address must resolve by pubkey'
        }

        $script:polls = 0; $script:dials = 0; $script:readyAfter = [int]::MaxValue
        $failed = $false
        try { Wait-FiberPeerConnected -Settings $settings -TimeoutSeconds 1 }
        catch {
            if ($_.Exception.Message -notlike '*is disconnected after*') { throw }
            $failed = $true
        }
        if (-not $failed) { throw 'An unrelated peer must not satisfy the expected connection' }
    }
    finally {
        Remove-Item Function:script:Invoke-RestMethod
        Remove-Variable polls, dials, readyAfter, lastDial -Scope Script -ErrorAction SilentlyContinue
    }
}
Write-Host 'Peer connectivity checks passed'

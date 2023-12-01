﻿function Invoke-GraphRequestBatch
{
    <#
    .SYNOPSIS
        Invoke a batch request against the graph API
    .DESCRIPTION
        Invoke a batch request against the graph API in batches of twenty.
        Breaking with the easy queries from Invoke-GraphRequest, this function
        requires you to provide a list of batches consisting of url, method and id.
    .PARAMETER Request
        A list of batches consisting of url, method and id.
    .EXAMPLE
        $servicePrincipals = Invoke-GraphRequest -Query "servicePrincipals?&`$filter=accountEnabled eq true"
        $araCounter = 1
        $idToSp = @{}
        $appRoleAssignmentsRequest = foreach ($sp in $servicePrincipals)
        {
            @{
                url    = "/servicePrincipals/$($sp.id)/appRoleAssignments"
                method = "GET"
                id     = $araCounter
            }
            $idToSp[$araCounter] = $sp
            $araCounter++
        }
    .OUTPUTS
        PSCustomObject with properties id and body to be able to match responses to requests.
    #>
    param
    (
        [Parameter(Mandatory)]
        [hashtable[]]
        $Request
    )

    $batchSize = 20 # Currently hardcoded API limit
    $counter = [pscustomobject] @{ Value = 0 }
    $batches = $Request | Group-Object -Property { [math]::Floor($counter.Value++ / $batchSize) } -AsHashTable

    foreach ($batch in ($batches.GetEnumerator() | Sort-Object -Property Key))
    {
        [array] $innerResult = try
        {
            $jsonbody = @{requests = [array]$batch.Value } | ConvertTo-Json -Depth 42 -Compress
            (Invoke-GraphRequest -Query '$batch' -Method Post -Body $jsonbody -ErrorAction Stop).responses
        }
        catch
        {
            Write-Error -Message "Error sending batch: $($_.Exception.Message)" -TargetObject $jsonbody
        }

        $throttledRequests = $innerResult | Where-Object status -eq 429
        $failedRequests = $innerResult | Where-Object { $_.status -ne 429 -and $_.status -in (400..499) }
        $successRequests = $innerResult | Where-Object status -in (200..299)

        if ($successRequests)
        {
            $successRequests | Select-Object id, @{ Name = 'body'; Expression = { $_.body } }
        }

        if ($throttledRequests)
        {
            $interval = ($throttledRequests.Headers | Sort-Object 'Retry-After' | Select-Object -Last 1).'Retry-After'
            Write-Verbose -Message "Throttled requests detected, waiting $interval seconds before retrying"

            Start-Sleep -Seconds $interval
            $retry = $Request | Where-Object id -in $throttledRequests.id

            try
            {
                [array](Invoke-GraphRequestBatch -Request $retry -ErrorAction Stop).responses | Select-Object id, @{ Name = 'body'; Expression = { $_.body } }
            }
            catch
            {
                Write-Error -Message "Error sending retry batch: $($_.Exception.Message)" -TargetObject $retry
            }
        }

        foreach ($failedRequest in $failedRequests)
        {
            Write-Error -Message "Error in batch request $($failedRequest.id): $($failedRequest.body.error.message)"
        }
    }
}

<#
PLEASE READ README.txt BEFORE USE THIS SCRIPT

IMPORTANT: if there are error during script remove:
 - removed eventualy index created
 - restore old index
 - remove repository with snapshot 
 - remove repository folder
 - reduce batchSize
 - rerun script
 #>

# PARAM (adjust as needed)
#number of document to reindex simultaneas
$batchSize = 500
# log file
$fileLog = "<file-log-path>"
#must to be new repository not set an existing repository
$repository="<repository-name>"
#name of snapshot
$snapshot="<snapshot-name>"
#index temporary used to restore -cr index
$temporaryIndex = "<index-name-temp>"
#-cr index to use to snapshot and deleted 
$indexToMigrated = "<index-name-to-migrates>"
#-cr new index with correct field mapping (for real migration this name must to be equale a indexToMigrated)
$destIndex = "<index-name-to-migrates>"
#elastic url
$elasticUrl = "<elastic-url>"
$useBulk = $false
$removeTemporaryIndex = $false
$documentIndexPayload = "<new-index-with-different-mapping>"

# PARAM (NOT CHANGE)
$iter = 1
$totalDocumentIndexed = 0
$retryMaxAction = 5


#use reindex elastic API
function Reindex {
  param (
    $documents
  )
  
  $ids = ""
  $retryAction = 1

  foreach ($doc in $documents) 
  {
    
    $ids += """"+$doc._id + ""","      
  }
  $ids = $ids.Substring(0, $ids.Length - 1)
  $payload = "{""source"":{""index"":""$temporaryIndex"",""query"":{""terms"":{""_id"":[$ids]}}},""dest"":{""index"":""$destIndex""}}"
  while($retryAction -le  $retryMaxAction)
  {
    try
    {
      $reindexReponse = Invoke-RestMethod -Uri "$elasticUrl/_reindex" -Method Post -Body ($payload -join "`r`n") -ContentType "application/json"
      break;
    }
    catch
    {
      Write-Error "ERROR CALL REINDEX API: "$_.Exception.ToString()
      Start-Sleep -Seconds 2
      $retryAction ++
    }
  } 
  
  if($reindexReponse.total -ne $documents.Count)
  {
    write-host "ERROR REINDEX"
    write-host "reindexReponse: " $reindexReponse
    Add-Content -Path $fileLog -Value $ids
  }
  
  return $reindexReponse.total  
}

#use bulk elastic API
function Bulk {
  param (
		$documents
	)

  $payload = ""
  foreach ($doc in $documents) {
    # Add action object for each document
    $payload += "{""index"":{ ""_index"":""$destIndex""}}" + "`r`n"
    $payload += $doc._source | ConvertTo-Json -Compress -EscapeHandling EscapeHtml
    $payload += "`r`n"
  }
  
  # Perform bulk indexing
  $bulkReponse = Invoke-RestMethod -Uri "$elasticUrl/_bulk" -Method Post -Body ($payload -join "`r`n") -ContentType "application/json"
  
  if($bulkReponse.errors)
  {
    write-host "ERROR MASSIVE BULK START MASSIVE REINDEX"
    write-host "bulkReponse: " $reindexReponse
    $ids = ""
    foreach ($doc in $documents) 
    {
      $ids += """"+$doc._id + ""","      
    }
    Add-Content -Path $fileLog -Value $ids        
  }
    return $documents.Count
}

function DeleteIndex {
  param (
    $index
  )
  Invoke-RestMethod -Uri "$elasticUrl/$index" -Method DELETE -ContentType "application/json"
}

#START SCRIPT
#create new repository and snapshot
write-host "CREATE REPOSITORY $repository AND SNAPSHOT $snapshot FOR INDEX: $indexToMigrated"
$repoPayload="{""type"": ""fs"",""settings"":{""location"": ""$repository""}}"
Invoke-RestMethod -Uri "$elasticUrl/_snapshot/$repository" -Method PUT -Body ($repoPayload -join "`r`n") -ContentType "application/json"

$snapshoturl = $elasticUrl + "/_snapshot/" + $repository + "/" + $snapshot + "?wait_for_completion=true"
$snapshotPayload = "{""indices"":""$indexToMigrated""}"
$snapshotResponse = Invoke-RestMethod -Uri $snapshoturl -Method PUT -Body ($snapshotPayload -join "`r`n") -ContentType "application/json"

if($snapshotResponse.snapshot.state -ne "SUCCESS")
{
  Write-Error "CANNOT CREATE SNAPSHOT CLEAN REPOSITORY AND RETRY"
  exit
}

#restore snapshot in temporary 
write-host "RESTORE SNAPSHOT $snapshot FOR INDEX: $indexToMigrated IN INDEX: $temporaryIndex"
$restoreUrl = $elasticUrl + "/_snapshot/" + $repository +"/" + $snapshot +"/_restore?wait_for_completion=true"
$restorePaylod = "{""indices"": ""$indexToMigrated"",""ignore_unavailable"":""true"",""include_global_state"":false,""rename_pattern"": ""$indexToMigrated"",""rename_replacement"":""$temporaryIndex""}"
$restoreResponse = Invoke-RestMethod -Uri $restoreUrl -Method POST -Body ($restorePaylod -join "`r`n") -ContentType "application/json"

if( -not $restoreResponse)
{
  Write-Error "CANNOT RESTORE CLEAN REPOSITORY AND RETRY"
  DeleteIndex $temporaryIndex
  DeleteIndex "_snapshot/$repository"
  exit
}

#delete indexToMigrated
write-host "DELETE INDEX: $indexToMigrated"
Invoke-RestMethod -Uri "$elasticUrl/$indexToMigrated" -Method DELETE -ContentType "application/json"

#create new index with correct Mapping
write-host "CREATE INDEX: $destIndex"
Invoke-RestMethod -Uri "$elasticUrl/$destIndex" -Method PUT -Body ($documentIndexPayload -join "`r`n") -ContentType "application/json"


# Initial scroll ID
write-host "START REINDEX DOCUMENT AS IS FROM $temporaryIndex TO $destIndex IN $elasticUrl ELASTIC CLUSTER"
$Response = Invoke-RestMethod -Uri "$elasticUrl/$temporaryIndex/_search?scroll=1m&size=$batchSize"
$scrollId = $Response._scroll_id
$documents = $Response.hits.hits 
$totalDocumentToIndex = $Response.hits.total.value

write-host "FOUND DOCUMENTS: " $totalDocumentToIndex
 while($true)
{
  # Check for end of scroll
  if ($documents.Count -eq 0) {
    break
  }
  
  # Build bulk indexing payload
  if($useBulk)
  {
    write-host "$iter- BULK: " $documents.Count "documents"
    $totalDocumentIndexed += Bulk -documents $documents  
  }
  else
  {
    write-host "$iter- REINDEX: " $documents.Count "documents"
    $totalDocumentIndexed += Reindex -documents $documents
  }
  
  write-host "$iter- indexed: " $totalDocumentIndexed "/"  $totalDocumentToIndex

  # Retrieve documents in batch
  $payload = "{""scroll"":""1m"", ""scroll_id"": ""$scrollId""}"
  $documentsResponse = Invoke-RestMethod -Uri "$elasticUrl/_search/scroll" -Method POST -Body ($payload -join "`r`n") -ContentType "application/json"
  $documents = $documentsResponse.hits.hits
  $iter++
} 
  
# refresh index
write-host "END REINDEX EXECUTE REFRESH FOR INDEX: $destIndex" 
$refreshResponse = Invoke-RestMethod -Uri "$elasticUrl/$destIndex/_refresh" -Method Post -ContentType "application/json"
  
# remove scrollId
write-host "REMOVE SCROLLID $scrollId"
$payload = "{""scroll_id"": ""$scrollId""}"
$deleteResponse = Invoke-RestMethod -Uri "$elasticUrl/_search/scroll" -Method DELETE -Body ($payload -join "`r`n") -ContentType "application/json"

if($removeTemporaryIndex)
{
  #delete indexToMigrated
  Invoke-RestMethod -Uri "$elasticUrl/$temporaryIndex" -Method DELETE -ContentType "application/json"

}

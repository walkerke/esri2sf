#' main function
#' This function is the interface to the user.
#' @import jsonlite httr sf dplyr
#' @param url string for service url. ex) \url{https://sampleserver1.arcgisonline.com/ArcGIS/rest/services/Demographics/ESRI_Census_USA/MapServer/3}
#' @param outFields vector of fields you want to include. default is '*' for all fields
#' @param where string for where condition. default is 1=1 for all rows
#' @param token. string for authentication token if needed.
#' @param geomType string specifying the layer geometry ('esriGeometryPolygon' or 'esriGeometryPoint' or 'esriGeometryPolyline' - if NULL, will try to be infered from the server)
#' @return sf dataframe
#' @note When accessing services with multiple layers, the layer number must be specified at the end of the service url
#' (e.g., \url{https://sampleserver1.arcgisonline.com/ArcGIS/rest/services/Demographics/ESRI_Census_USA/MapServer/3}).
#'
#' The list of layers and their respective id numbers can be found by viewing the service's url in a web broswer
#' and viewing the "Layers" heading
#' (e.g.,\url{https://sampleserver1.arcgisonline.com/ArcGIS/rest/services/Demographics/ESRI_Census_USA/MapServer/#mapLayerList}).
#' @examples
#' url <- "https://sampleserver1.arcgisonline.com/ArcGIS/rest/services/Demographics/ESRI_Census_USA/MapServer/3"
#' outFields <- c("POP2007", "POP2000")
#' where <- "STATE_NAME = 'Michigan'"
#' df <- esri2sf(url, outFields=outFields, where=where)
#' plot(df)
#' @export
esri2sf <- function(url, outFields=c("*"), where="1=1", token='', geomType=NULL) {
  library(httr)
  library(jsonlite)
  library(sf)
  library(dplyr)
  layerInfo <- jsonlite::fromJSON(
    httr::content(
      httr::POST(
        url,
        query=list(f="json", token=token),
        encode="form",
        config = httr::config(ssl_verifypeer = FALSE)
        ),
      as="text"
      )
    )
  print(layerInfo$type)
  if (is.null(geomType)) {
    if (is.null(layerInfo$geometryType))
      stop("geomType is NULL and layer geometry type ('esriGeometryPolygon' or 'esriGeometryPoint' or 'esriGeometryPolyline') could not be infered from server.")

    geomType <- layerInfo$geometryType
  }
  print(geomType)
  queryUrl <- paste(url, "query", sep="/")
  esriFeatures <- getEsriFeatures(queryUrl, outFields, where, token)
  simpleFeatures <- esri2sfGeom(esriFeatures, geomType)
  return(simpleFeatures)
}

getEsriFeatures <- function(queryUrl, fields, where, token='') {
  ids <- getObjectIds(queryUrl, where, token)
  if(is.null(ids)){
    warning("No records match the search critera")
    return()
  }
  idSplits <- split(ids, ceiling(seq_along(ids)/500))
  results <- lapply(idSplits, getEsriFeaturesByIds, queryUrl, fields, token)
  merged <- unlist(results, recursive=FALSE)
  return(merged)
}

getObjectIds <- function(queryUrl, where, token=''){
  # create Simple Features from ArcGIS servers json response
  query <- list(
    where=where,
    returnIdsOnly="true",
    token=token,
    f="json"
  )
  responseRaw <- httr::content(
    httr::POST(
      queryUrl,
      body=query,
      encode="form",
      config = httr::config(ssl_verifypeer = FALSE)),
    as="text"
    )
  response <- jsonlite::fromJSON(responseRaw)
  return(response$objectIds)
}

getEsriFeaturesByIds <- function(ids, queryUrl, fields, token=''){
  # create Simple Features from ArcGIS servers json response
  query <- list(
    objectIds=paste(ids, collapse=","),
    outFields=paste(fields, collapse=","),
    token=token,
    outSR='4326',
    f="json"
  )
  responseRaw <- httr::content(
    httr::POST(
      queryUrl,
      body=query,
      encode="form",
      config = httr::config(ssl_verifypeer = FALSE)
      ),
    as="text"
    )
  response <- jsonlite::fromJSON(responseRaw,
                       simplifyDataFrame = FALSE,
                       simplifyVector = FALSE,
                       digits=NA)
  esriJsonFeatures <- response$features
  return(esriJsonFeatures)
}

esri2sfGeom <- function(jsonFeats, geomType) {
  # convert esri json to simple feature
  if (geomType == 'esriGeometryPolygon') {
    geoms <- esri2sfPolygon(jsonFeats)
  }
  if (geomType == 'esriGeometryPoint') {
    geoms <- esri2sfPoint(jsonFeats)
  }
  if (geomType == 'esriGeometryPolyline') {
    geoms <- esri2sfPolyline(jsonFeats)
  }
  # attributes
  atts <- lapply(jsonFeats, '[[', 1) %>%
          lapply(function(att) lapply(att, function(x) return(ifelse(is.null(x), NA, x))))

  af <- dplyr::bind_rows(lapply(atts, as.data.frame.list, stringsAsFactors=FALSE))
  # geometry + attributes
  df <- sf::st_sf(geoms, af, crs = 4326)
  return(df)
}

esri2sfPoint <- function(features) {
  getPointGeometry <- function(feature) {
    if (is.numeric(unlist(feature$geometry))){
      return(sf::st_point(unlist(feature$geometry)))
    } else {
      return(sf::st_point())
    }
  }
  geoms <- sf::st_sfc(lapply(features, getPointGeometry))
  return(geoms)
}

esri2sfPolygon <- function(features) {
  ring2matrix <- function(ring) {
    return(do.call(rbind, lapply(ring, unlist)))
  }
  rings2multipoly <- function(rings) {
    return(sf::st_multipolygon(list(lapply(rings, ring2matrix))))
  }
  getGeometry <- function(feature) {
    if(is.null(unlist(feature$geometry$rings))){
      return(sf::st_multipolygon())
    } else {
      return(rings2multipoly(feature$geometry$rings))
    }
  }
  geoms <- sf::st_sfc(lapply(features, getGeometry))
  return(geoms)
}

esri2sfPolyline <- function(features) {
  path2matrix <- function(path) {
    return(do.call(rbind, lapply(path, unlist)))
  }
  paths2multiline <- function(paths) {
    return(sf::st_multilinestring(lapply(paths, path2matrix)))
  }
  getGeometry <- function(feature) {
    return(paths2multiline(feature$geometry$paths))
  }
  geoms <- sf::st_sfc(lapply(features, getGeometry))
  return(geoms)
}

#' @export
generateToken <- function(server, uid, pwd='', expiration=5000){
  # generate auth token from GIS server
  if (pwd=='') {
     pwd <- rstudioapi::askForPassword("pwd")
  }
  query <- list(
    username=uid,
    password=pwd,
    expiration=expiration,
    client="requestip",
    f="json"
  )
  url <- paste(server, "arcgis/admin/generateToken", sep="/")
  r <- httr::POST(url, body=query, encode="form")
  token <- jsonlite::fromJSON(httr::content(r, "parsed"))$token
  return(token)
}

#' Generate a OAuth token for Arcgis Online
#' @param clientId string clientId
#' @param clientSecret  string clientSecret.
#' @return string token
#'
#' How to obtain clientId and clientSecret is described here:
#' https://developers.arcgis.com/documentation/core-concepts/security-and-authentication/accessing-arcgis-online-services/
#' @export
generateOAuthToken <- function(clientId,clientSecret,expiration=5000) {

    query=list(client_id=clientId,
               client_secret=clientSecret,
               expiration=expiration,
               grant_type="client_credentials")

    r <- httr::POST("https://www.arcgis.com/sharing/rest/oauth2/token",body=query)
    token <- content(r,type = "application/json")$access_token
    return(token)
}

#!/bin/bash

# set -x
set -uo pipefail

source ./logger.sh

configmap_json=$(oc get configmap -n$MY_NAMESPACE reconciler-config -ojson)

if [[ $? != 0 ]] ; then
  logger "ERROR" "config" ''oc get configmap -n$MY_NAMESPACE reconciler-config' rc != 0'
  logger "ERROR" "config" "Unable to load ConfigMap 'reconciler-config'..."
  exit 1
fi

BGP_VRF=$(echo $configmap_json | jq -r .data.bgp_vrf)
LABEL_SELECTOR=$(echo $configmap_json | jq -r .data.configmap_label_selector)
NAMESPACE=$(echo $configmap_json | jq -r .data.webhook_server_namespace)
SLEEP_DURATION=$(echo $configmap_json | jq -r .data.sleep_duration)
WHISPER=true

if [[ -z "$BGP_VRF" || -z "$LABEL_SELECTOR" || -z "$NAMESPACE" || -z "$SLEEP_DURATION" ]] ; then
  logger "ERROR" "config" "Unable to validate all configuration variables are set!"
  exit 1
fi

logger "DEBUG" "config" "BGP_VRF=$BGP_VRF"
logger "DEBUG" "config" "LABEL_SELECTOR=$LABEL_SELECTOR"
logger "DEBUG" "config" "NAMESPACE=$NAMESPACE"
logger "DEBUG" "config" "SLEEP_DURATION=$SLEEP_DURATION"

vrf_route_add() {
  if [[ "$#" != 2 ]] ; then
    logger "ERROR" "vrf_route_add" "vrf_route_add <cudn_name> <cudn_subnets>"
    exit 1
  fi

  local cudn_name="$1"
  local cudn_subnets="$2"

  logger "DEBUG" "vrf_route_add" "cudn_name=$cudn_name"
  logger "DEBUG" "vrf_route_add" "cudn_subnets=$cudn_subnets"

  ip_show_master=$(ip link show master $cudn_name 2>/dev/null)

  if [[ $? != 0 ]] ; then
    logger "ERROR" "vrf_route_add" "'ip link show master $cudn_name' rc != 0"
    logger "ERROR" "vrf_route_add" "This could mean a Namespace using the ClusterUserDefinedNetwork '$cudn_name' has not been created..."
    return
  fi

  cudn_vrf_master=$(echo $ip_show_master | grep $cudn_name | cut -d: -f2 | sed 's/^ //g')

  logger "DEBUG" "vrf_route_add" "cudn_vrf_master=$cudn_vrf_master"
  logger "INFO" "vrf_route_add" "Creating a route in vrf $BGP_VRF for each subnet in ClusterUserDefinedNetwork $cudn_name"

  for subnet in $(echo $(echo $cudn_subnets | jq -r .[]))
  do
    # confirmed working with layer2
    existing_route=$(ip route list vrf $BGP_VRF scope link exact $subnet)

    if [[ ${#existing_route} != 0 ]] ; then
      logger "DEBUG" "vrf_route_add" "Route for subnet $subnet already whispered to vrf $BGP_VRF..."
      continue
    fi

    logger "DEBUG" "vrf_route_add" "Adding route to $subnet via $cudn_vrf_master on vrf $BGP_VRF..."
    ip route add $subnet dev $cudn_vrf_master vrf $BGP_VRF

    if [[ $? != 0 ]] ; then
      logger "ERROR" "vrf_route_add" "'ip route add $subnet dev $cudn_vrf_master vrf $BGP_VRF' rc != 0"
      logger "ERROR" "vrf_route_add" "COULD NOT ADD ROUTE TO VRF!"
      continue
    fi
  done
}

function vrf_route_remove() {
  if [[ "$#" != 2 ]] ; then
    logger "ERROR" "vrf_route_remove" "vrf_route_remove <cudn_name> <cudn_subnets>"
    exit 1
  fi

  local cudn_name="$1"
  local cudn_subnets="$2"

  for subnet in $(echo $(echo $cudn_subnets | jq -r .[]))
  do
    # confirmed working with layer2
    existing_route=$(ip route list vrf $BGP_VRF scope link exact $subnet)

    if [[ ${#existing_route} == 0 ]] ; then
      logger "DEBUG" "vrf_route_remove" "'ip link show master $cudn_name' rc != 0"
      logger "INFO" "vrf_route_remove" "No route found for $subnet in vrf $BGP_VRF for ClusterUserDefiendNetwork $cudn_name"
      continue
    fi

    logger "DEBUG" "vrf_route_remove" "Removing route to $subnet on vrf $BGP_VRF..."
    ip route del vrf $BGP_VRF $subnet

    if [[ $? != 0 ]] ; then
      logger "ERROR" "vrf_route_remove" "'ip route del vrf $BGP_VRF $subnet' rc != 0"
      logger "ERROR" "vrf_route_remove" "COULD NOT REMOVE ROUTE FROM VRF!"
      continue
    fi
  done
}

trap 'WHISPER=false' SIGTERM SIGINT

logger "INFO" "startup" "Entering reconcilliation loop..."

while $WHISPER
do
  # Loop start time in milliseconds
  loop_start=$(date +%s%3N)

  # Find all ConfigMaps in $NAMESPACE using the label selector $LABEL_SELECTOR
  CONFIGMAPS=$(oc get configmap -n$NAMESPACE -l$LABEL_SELECTOR --no-headers -ocustom-columns=:.metadata.name)

  logger "DEBUG" "loop" "Found ConfigMaps: [$(echo $CONFIGMAPS | sed 's/ /,/g')]..."

  # Iterate through $CONFIGMAPS and take action based on populate field
  for configmap in $(echo $CONFIGMAPS)
  do
    # Extract ConfigMap YAML
    configmap_json=$(oc get configmap -n$NAMESPACE $configmap -ojson | jq -r .data)

    if [[ $? != 0 ]] ; then
      logger "ERROR" "loop" "'oc get configmap -n$NAMESPACE $configmap -ojson | jq -r .data' rc != 0"
      logger "ERROR" "loop" "Could not retrieve contents of ConfigMap $configmap!"
      continue
    fi

    cudn_name=$configmap
    cudn_populate=$(echo $configmap_json | jq -r .populate)
    cudn_subnets=$(echo $configmap_json | jq -r .subnets)

    if [[ $cudn_populate == "true" ]] ; then
      logger "DEBUG" "loop" "Calling vrf_route_add \"$cudn_name\" \"$cudn_subnets\""
      vrf_route_add "$cudn_name" "$cudn_subnets"
    else
      logger "DEBUG" "loop" "Calling vrf_route_remove \"$cudn_name\" \"$cudn_subnets\""
      vrf_route_remove "$cudn_name" "$cudn_subnets"
    fi
  done

  loop_end=$(date +%s%3N)

  printf -v loop_duration "%.2f" "$(( $(date +%s%3N) - loop_start ))e-3"
  logger "INFO" "loop" "Reconcilliation took ${loop_duration}s, sleeping for ${SLEEP_DURATION}s..."

  sleep 10
done

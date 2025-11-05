import argparse, base64, json, signal, sys, yaml
from datetime import datetime, timezone
from flask import Flask, jsonify, request, Response
from gevent.pywsgi import WSGIServer
from gevent import signal as gevent_signal
from kubernetes import client, config
from kubernetes.client.exceptions import ApiException

app = Flask(__name__)

parser = argparse.ArgumentParser()

parser.add_argument("-d", "--debug", action="store_true", required=False, help="Dump request and response payloads in JSON format to stderr")
parser.add_argument("-c", "--cert-file", required=True, help="Location of PEM encoded TLS certificate file")
parser.add_argument("-k", "--key-file", required=True, help="Location of PEM encoded TLS private key file")
parser.add_argument("-p", "--https-port", type=int, required=True, help="TCP port to bind app server to")
parser.add_argument("-n", "--namespace", required=True, help="Namespace where the webhook server stores the ConfigMaps referenced by the route reconciler")

args = parser.parse_args()

def _load_kube_configuration():
    try:
        config.load_incluster_config()
    except config.ConfigException:
        config.load_kube_config()

    return client.Configuration.get_default_copy()

kube_configuration = _load_kube_configuration()

def log(message: str, show_date: bool = True) -> None:
    if show_date == True:
        now_utc = datetime.now(timezone.utc)
        sys.stdout.write(f"{now_utc:%Y-%m-%d %H:%M:%S.%f} - ")
    sys.stdout.write(f"{message}\n")

def build_response(uid: str, json_patches: list[dict] = None, allowed: bool = True) -> Response:
    response = {
        "apiVersion": "admission.k8s.io/v1",
        "kind": "AdmissionReview",
        "response": {
            "allowed": allowed,
            "uid": uid
        }
    }

    if json_patches:
        response["response"]["patch"] = base64.b64encode(
            json.dumps(json_patches).encode("utf-8")
        ).decode("ascii")
        response["response"]["patchType"] = "JSONPatch"

    if args.debug:
        log("Dumping AdmissionReview/AdmissionResponse payload YAML...")
        log("---\n" + yaml.dump(response, default_flow_style=False, sort_keys=True), show_date=False)

    return jsonify(response)

# Called when a ClusterUserDefinedNetwork is created. Mutates ClusterUserDefinedNetwork by
# adding a label and creates ConfigMap that route reconciler DaemonSet will use to publish route
# on specified VRF.

def handle_create(admission_request: dict) -> Response:
    cudn_name = admission_request.get('name')
    namespace = args.namespace
    object = admission_request.get('object') or {}
    subnets = object.get('spec').get('network').get('layer2').get('subnets')

    if args.debug:
        log(f"DEBUG: Found ClusterUserDefinedNetwork {cudn_name} with the following subnets:")
        log("---\n" + yaml.dump(subnets, default_flow_style=False, sort_keys=True), show_date=False)

    # Add label route-whisperer.openinfra.io/configmap=$cudn_name to ClusterUserDefinedNetwork.
    # This validates the webhook has created the ConfigMap and serves as a reference.

    json_patches = [{
        "op": "add",
        "path": "/metadata/labels/route-whisperer.openinfra.io~1configmap",
        "value": cudn_name
    }]

    with client.ApiClient(kube_configuration) as api_client:
        v1 = client.CoreV1Api(api_client)

        configmap = client.V1ConfigMap(
            metadata=client.V1ObjectMeta(
                labels={"route-whisperer.openinfra.io": ""},
                name=cudn_name
            ),
            data={
                'subnets': json.dumps(subnets, separators=(',', ':')),
                'populate': 'true'
            }
        )

        # More often than not we are creating a ConfigMap, so just try that first. If the ConfigMap
        # already exists (409 Conflict), update it instead. This scenario would occur when a
        # ClusterUserDefiendNetwork is deleted and then recreated. Otherwise raise the exception. 

        try:
            v1.create_namespaced_config_map(namespace=namespace, body=configmap)
            log(f"CREATED ConfigMap {cudn_name} in namespace {namespace}...")
        except ApiException as e:
            if e.status == 409:
                v1.patch_namespaced_config_map(
                    name=cudn_name,
                    namespace=namespace,
                    body={
                        'data':{
                            'subnets': json.dumps(subnets, separators=(',', ':')),
                            'populate':'true'
                        }
                    }
                )
                log(f"UPDATED ConfigMap {cudn_name} in namespace {namespace}...")
            else:
                raise

        if args.debug:
            log(f"DEBUG: Dumping json_patches as YAML...")
            log("---\n" + yaml.dump(json_patches, default_flow_style=False, sort_keys=True), show_date=False)

        return build_response(
            uid=admission_request.get('uid'),
            json_patches=json_patches
        )

# Called when a ClusterUserDefinedNetwork is deleted. ConfigMap for route reconciler DaemonSet
# is updated to ensure route is removed from specified 

def handle_delete(admission_request: dict) -> Response:
    cudn_name = admission_request.get('name')
    namespace = args.namespace
    object = admission_request.get('oldObject') or {}
    subnets = object.get('spec').get('network').get('layer2').get('subnets')

    if args.debug:
        log(f"Found ClusterUserDefinedNetwork {cudn_name} with the following subnets:")
        log("---\n" + yaml.dump(subnets, default_flow_style=False, sort_keys=True), show_date=False)
    
    with client.ApiClient(kube_configuration) as api_client:
        v1 = client.CoreV1Api(api_client)

        configmap = client.V1ConfigMap(
            metadata=client.V1ObjectMeta(
                labels={"route-whisperer.openinfra.io": ""},
                name=cudn_name
            ),
            data={
                'subnets': json.dumps(subnets, separators=(',', ':')),
                'populate': 'false'
            }
        )

        try:
            v1.create_namespaced_config_map(namespace=namespace, body=configmap)
            log(f"CREATED ConfigMap {cudn_name} in namespace {namespace}...")
        except ApiException as e:
            if e.status == 409:
                v1.patch_namespaced_config_map(
                    name=cudn_name,
                    namespace=namespace,
                    body={
                        'data':{
                            'subnets': json.dumps(subnets, separators=(',', ':')),
                            'populate':'false'
                        }
                    }
                )
                log(f"UPDATED ConfigMap {cudn_name} in namespace {namespace}...")
            else:
                raise

    return build_response(uid=admission_request.get('uid'))

def start_whispering() -> None:
    server = WSGIServer(
        listener=("0.0.0.0", args.https_port),
        application=app,
        keyfile=args.key_file,
        certfile=args.cert_file
    )

    def _graceful_stop(signum, frame) -> None:
        try:
            server.stop(timeout=5)
        finally:
            server.close()
    
    gevent_signal.signal(signal.SIGTERM, _graceful_stop)
    gevent_signal.signal(signal.SIGINT, _graceful_stop)
    log(f"Starting gevent WSGIServer on https://0.0.0.0:{args.https_port}")
    server.serve_forever()

@app.route("/healthz")
def healthz() -> tuple[str, int]:
    return "ok", 200

@app.route("/mutate", methods=["POST"])
def mutate() -> Response:
    admission_review = request.get_json(force=True, silent=False)
    admission_request = admission_review.get('request')

    if args.debug:
        log("DEBUG: Dumping AdmissionReview/AdmissionRequest payload YAML...")
        log("---\n" + yaml.dump(admission_review, default_flow_style=False, sort_keys=True), show_date=False)

    if admission_request.get('operation') == 'CREATE':
        return handle_create(admission_request=admission_request)
    elif admission_request.get('operation') == 'DELETE':
        return handle_delete(admission_request=admission_request)
    else:
        return build_response(uid=admission_request.get('uid'))

if __name__ == "__main__":
    start_whispering()

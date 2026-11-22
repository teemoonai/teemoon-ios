#!/usr/bin/env python3
"""Replay conformance/signatures.json through near.ai's own inference-sdk.

Writes conformance/signatures.sdk.json: one verdict per case the SDK can
express. ConformanceSignatureTests.iosAgreesWithTheSDK holds iOS (and
Android, which vendors both files byte-identical) to the same verdicts.

Mac-only dev tool; the SDK never ships in the app. Offline: it calls only the
SDK's pure verifiers (core/chat.py), never the network. Install the pinned SDK
in a venv OUTSIDE the repo, and run with -I so nothing in the tree is imported:

    uv venv -p 3.12 ~/.cache/teemoon-nearai-sdk-4bccfd9
    VIRTUAL_ENV=~/.cache/teemoon-nearai-sdk-4bccfd9 uv pip install \
      "nearai-inference-sdk @ git+https://github.com/nearai/inference-sdk@4bccfd94549f6e5061821f90a5d8901d7299a8c0#subdirectory=py"
    ~/.cache/teemoon-nearai-sdk-4bccfd9/bin/python -I conformance/tools/sdk_verdicts.py conformance

How a case maps onto the SDK, the way its client would call it:
- the signature payload is validated with CloudCompletionSignatureSchema
  (an unknown signing_algo or signature_kind fails there: "rejected");
- provider_tee -> verify_model_response against the model signer the
  attestation holds for that algo (ed25519: modelKey, ecdsa: gpuAddress);
- gateway -> verify_gateway_response against the gateway's ecdsa address;
- the request body is requestBodiesB64[0], the bytes on the wire.
A pass is "verified" (model) or "gatewayTrustOnly" (gateway). Key-to-quote
binding lives in the SDK's attestation layer, so cases with sdkApplies=false
are skipped.
"""

import base64
import importlib.metadata
import json
import sys
from pathlib import Path
from types import SimpleNamespace

from nearai_inference_sdk.core.chat import verify_gateway_response, verify_model_response
from nearai_inference_sdk.schemas import CloudCompletionSignatureSchema
from nearai_inference_sdk.types.attestation_common import SigningIdentity
from nearai_inference_sdk.types.chat import CompletionSignature

PINNED = "4bccfd94549f6e5061821f90a5d8901d7299a8c0"


def installed_commit() -> str:
    direct = importlib.metadata.distribution("nearai-inference-sdk").read_text("direct_url.json") or "{}"
    return json.loads(direct).get("vcs_info", {}).get("commit_id", "")


def verdict(case: dict) -> str:
    s = case["signature"]
    raw = {"text": s["text"], "signature": s["signature"],
           "signing_address": s["signingAddress"], "signing_algo": s["signingAlgo"],
           "signature_kind": s.get("signatureKind") or "provider_tee"}
    try:
        parsed = CloudCompletionSignatureSchema.model_validate(raw)
    except Exception:
        return "rejected"
    sig = CompletionSignature(kind=parsed.signature_kind,
                              signer=SigningIdentity(signing_algo=parsed.signing_algo,
                                                     signing_address=parsed.signing_address),
                              signed_text=parsed.text, signature=parsed.signature)
    att = case["attestation"]
    request = base64.b64decode(case["requestBodiesB64"][0])
    response = case["responseText"].encode()
    try:
        if parsed.signature_kind == "gateway":
            if not att.get("gatewayAddress"):
                return "rejected"
            signer = SigningIdentity(signing_algo="ecdsa", signing_address=att["gatewayAddress"])
            verify_gateway_response(request, response, sig, SimpleNamespace(signer=signer))
            return "gatewayTrustOnly"
        address = att.get("modelKey") if parsed.signing_algo == "ed25519" else att.get("gpuAddress")
        if not address:
            return "rejected"
        signer = SigningIdentity(signing_algo=parsed.signing_algo, signing_address=address)
        verify_model_response(request, response, sig, SimpleNamespace(signer=signer))
        return "verified"
    except Exception:
        return "rejected"


def main() -> None:
    root = Path(sys.argv[1] if len(sys.argv) > 1 else "conformance")
    commit = installed_commit()
    if commit != PINNED:
        sys.exit(f"installed SDK is at {commit or 'an unknown commit'}, expected {PINNED}")
    doc = json.loads((root / "signatures.json").read_text())
    cases = doc["vectors"]["cases"]
    verdicts = {c["note"]: verdict(c) for c in cases if c["sdkApplies"]}
    out = {"sdk": "nearai/inference-sdk", "sdkCommit": PINNED, "verdicts": verdicts}
    (root / "signatures.sdk.json").write_text(json.dumps(out, indent=2, sort_keys=True) + "\n")
    for c in cases:
        if c["sdkApplies"]:
            mark = "ok  " if verdicts[c["note"]] == c["outcome"] else "DIFF"
            print(f"{mark} sdk={verdicts[c['note']]:<17} ios={c['outcome']:<17} {c['note']}")


if __name__ == "__main__":
    main()

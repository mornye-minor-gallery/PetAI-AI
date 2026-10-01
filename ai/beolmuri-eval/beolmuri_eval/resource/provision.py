"""Seed the model outside measurement; prove transferred bytes by roundtrip hash."""
from uuid import uuid4
from ..config import repository
from ..storage import atomic_json, read_json, run_lock
from .device import Device, ROOT
from .plan import inputs_from_config, verify_model
from .protocol import sha256


def provision_model(config_path, *, device_id, progress=lambda **kw: None):
    config,_,model,source,_,_=inputs_from_config(config_path)
    base=repository()/'ai/beolmuri-eval/.artifacts'
    folder=base/'resource-provisions'/str(uuid4());folder.mkdir(parents=True)
    device=Device(device_id,config['bundle_id'],folder/'device',progress=progress)
    details=device.details();atomic_json(folder/'device.json',details)
    canonical=details.get('hardwareProperties',{}).get('udid')
    if not canonical:raise RuntimeError('canonical device identity unavailable')
    device.identifier=canonical
    owner=base/'resource-devices'/sha256(canonical.lower().encode());owner.mkdir(parents=True,exist_ok=True)
    with run_lock(owner):
        active=owner/'active.json'
        if active.exists() and not read_json(active).get('termination_confirmed',False):
            raise RuntimeError('previous experiment termination must be confirmed before provisioning')
        verify_model(source,model['sha256'],progress=progress)
        destination=f"{ROOT}/models/{model['sha256']}.litertlm"
        try:
            progress(stage='provision_upload',bytes=source.stat().st_size)
            device.copy_to(source,destination,timeout=900)
            # Retain the returned file as transfer evidence; no automatic cleanup.
            returned=folder/'returned-model.litertlm'
            progress(stage='provision_verify_download',bytes=source.stat().st_size)
            device.copy_from(destination,returned,timeout=900)
            verify_model(returned,model['sha256'],progress=progress)
            result=dict(roundtrip_verified=True,inference_verified=False,
                        model_sha256=model['sha256'],bytes=returned.stat().st_size,
                        destination=destination,evidence=str(folder),
                        transport=details.get('connectionProperties',{}).get('transportType'))
            atomic_json(folder/'result.json',result)
            return result
        except BaseException as error:
            atomic_json(folder/'failure.json',dict(error=str(error),roundtrip_verified=False))
            raise

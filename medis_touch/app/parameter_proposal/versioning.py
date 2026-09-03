import hashlib
import json


def canonical_configuration(values):
    return json.dumps(values, sort_keys=True, separators=(",", ":"), ensure_ascii=False)


def configuration_hash(values):
    return hashlib.sha256(canonical_configuration(values).encode()).hexdigest()


def configuration_version(values):
    return "mtcfg_" + configuration_hash(values)[:16]

from .models import ParameterSet, ParameterSpec


def _values(spec: ParameterSpec, current):
    if spec.kind == "int":
        values = [int(current) + d * int(spec.step or 1) for d in (-2, -1, 0, 1, 2)]
    elif spec.kind == "float":
        values = [round(float(current) + d * float(spec.step or 0.01), 8) for d in (-2, -1, 0, 1, 2)]
    else:
        return [current]
    if spec.minimum is not None:
        values = [max(spec.minimum, v) for v in values]
    if spec.maximum is not None:
        values = [min(spec.maximum, v) for v in values]
    return sorted(set(values))


def generate_candidates(current: ParameterSet, specs: dict[str, ParameterSpec], max_candidates=250):
    result = []
    for name, spec in specs.items():
        if not spec.mutable:
            continue
        for value in _values(spec, current.values[name]):
            if value == current.values[name]:
                continue
            values = dict(current.values)
            values[name] = value
            result.append(ParameterSet(values, current.parent_version))
            if len(result) >= max_candidates:
                return result
    return result

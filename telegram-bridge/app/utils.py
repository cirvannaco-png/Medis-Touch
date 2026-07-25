import time
from loguru import logger


def measure_latency(start_time: float) -> int:
    latency = int((time.time() - start_time) * 1000)
    logger.info(f"Latency: {latency} ms")
    return latency

import os
import redis

_client = None


def get_redis():
    global _client
    if _client is None:
        _client = redis.Redis(
            host=os.environ.get("REDIS_HOST", "redis"),
            port=int(os.environ.get("REDIS_PORT", "6379")),
            decode_responses=True,
        )
    return _client
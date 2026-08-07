from __future__ import annotations

import json
import os
from typing import Any

import nats
from nats.js.api import AckPolicy, ConsumerConfig, RetentionPolicy, StreamConfig
from nats.js.errors import NotFoundError

STREAM = "CHESSFORGE"
SUBJECT = "chessforge.games"
DURABLE = "analyzers"
# Must exceed worst-case analyze time at depth 10 for sample games.
ACK_WAIT_SECONDS = 300


def nats_url() -> str:
    return os.environ.get("NATS_URL", "nats://127.0.0.1:4222")


def encode_job(payload: dict[str, Any]) -> bytes:
    return json.dumps(payload, separators=(",", ":")).encode("utf-8")


def decode_job(data: bytes) -> dict[str, Any]:
    return json.loads(data.decode("utf-8"))


async def connect_nats(url: str | None = None) -> nats.NATS:
    return await nats.connect(url or nats_url())


async def ensure_stream_and_consumer(js) -> None:
    try:
        await js.stream_info(STREAM)
    except NotFoundError:
        await js.add_stream(
            StreamConfig(
                name=STREAM,
                subjects=[SUBJECT],
                retention=RetentionPolicy.WORK_QUEUE,
            )
        )

    try:
        await js.consumer_info(STREAM, DURABLE)
    except NotFoundError:
        await js.add_consumer(
            STREAM,
            ConsumerConfig(
                durable_name=DURABLE,
                ack_policy=AckPolicy.EXPLICIT,
                ack_wait=ACK_WAIT_SECONDS,
                filter_subject=SUBJECT,
            ),
        )


async def publish_game(js, payload: dict[str, Any]) -> None:
    await js.publish(SUBJECT, encode_job(payload))


async def pull_subscribe(js):
    return await js.pull_subscribe(
        SUBJECT,
        durable=DURABLE,
        stream=STREAM,
    )

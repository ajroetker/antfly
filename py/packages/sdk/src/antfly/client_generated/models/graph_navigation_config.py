from __future__ import annotations

from collections.abc import Mapping
from typing import Any, TypeVar, cast

from attrs import define as _attrs_define

from ..models.edge_direction import EdgeDirection
from ..types import UNSET, Unset

T = TypeVar("T", bound="GraphNavigationConfig")


@_attrs_define
class GraphNavigationConfig:
    """Model-directed single-path navigation within this query's table. Requires
    agentic mode and a retrieval generator. Search starts the walk; subsequent
    navigation selects only an offered, unvisited neighbor. All reads enforce
    the retrieval request's mandatory predicates and authenticated row filters.
    Uses the enclosing agent's model, history, iteration budget and result.

        Attributes:
            index (str): Graph index used for every neighbor read.
            start_key (str | Unset): Explicit start node. If omitted, use the first hit of the query.
            direction (EdgeDirection | Unset): Direction of edges to query:
                - out: Outgoing edges from the node
                - in: Incoming edges to the node
                - both: Both outgoing and incoming edges
            edge_types (list[str] | Unset):
            max_steps (int | Unset): Maximum moves after the start node. The enclosing agent's iteration and tool limits
                also apply. Default: 8.
            neighbor_limit (int | Unset): Maximum candidate neighbors per node, further limited by the context budget.
                Default: 8.
            instruction (str | Unset): Optional caller-supplied workflow instruction retained in agent history.
            instruction_field (str | Unset): Explicitly opt in to following instructions from this top-level string
                field of each visited document. Instructions accumulate in agent history.
                Other document fields and unvisited neighbors remain untrusted evidence.
                The field must be included if the query uses a fields projection.
    """

    index: str
    start_key: str | Unset = UNSET
    direction: EdgeDirection | Unset = UNSET
    edge_types: list[str] | Unset = UNSET
    max_steps: int | Unset = 8
    neighbor_limit: int | Unset = 8
    instruction: str | Unset = UNSET
    instruction_field: str | Unset = UNSET

    def to_dict(self) -> dict[str, Any]:
        index = self.index

        start_key = self.start_key

        direction: str | Unset = UNSET
        if not isinstance(self.direction, Unset):
            direction = self.direction.value

        edge_types: list[str] | Unset = UNSET
        if not isinstance(self.edge_types, Unset):
            edge_types = self.edge_types

        max_steps = self.max_steps

        neighbor_limit = self.neighbor_limit

        instruction = self.instruction

        instruction_field = self.instruction_field

        field_dict: dict[str, Any] = {}

        field_dict.update(
            {
                "index": index,
            }
        )
        if start_key is not UNSET:
            field_dict["start_key"] = start_key
        if direction is not UNSET:
            field_dict["direction"] = direction
        if edge_types is not UNSET:
            field_dict["edge_types"] = edge_types
        if max_steps is not UNSET:
            field_dict["max_steps"] = max_steps
        if neighbor_limit is not UNSET:
            field_dict["neighbor_limit"] = neighbor_limit
        if instruction is not UNSET:
            field_dict["instruction"] = instruction
        if instruction_field is not UNSET:
            field_dict["instruction_field"] = instruction_field

        return field_dict

    @classmethod
    def from_dict(cls: type[T], src_dict: Mapping[str, Any]) -> T:
        d = dict(src_dict)
        index = d.pop("index")

        start_key = d.pop("start_key", UNSET)

        _direction = d.pop("direction", UNSET)
        direction: EdgeDirection | Unset
        if isinstance(_direction, Unset):
            direction = UNSET
        else:
            direction = EdgeDirection(_direction)

        edge_types = cast(list[str], d.pop("edge_types", UNSET))

        max_steps = d.pop("max_steps", UNSET)

        neighbor_limit = d.pop("neighbor_limit", UNSET)

        instruction = d.pop("instruction", UNSET)

        instruction_field = d.pop("instruction_field", UNSET)

        graph_navigation_config = cls(
            index=index,
            start_key=start_key,
            direction=direction,
            edge_types=edge_types,
            max_steps=max_steps,
            neighbor_limit=neighbor_limit,
            instruction=instruction,
            instruction_field=instruction_field,
        )

        return graph_navigation_config

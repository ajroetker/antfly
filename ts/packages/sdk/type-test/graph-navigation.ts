import type { GraphNavigationConfig, QueryRequest, RetrievalAgentRequest } from "../src/index.js";

const navigation: GraphNavigationConfig = {
  index: "workflow",
  start_key: "start",
  direction: "in",
  edge_types: ["next"],
  instruction_field: "instructions",
  max_steps: 4,
  neighbor_limit: 8,
};

const request: RetrievalAgentRequest = {
  query: "Find the resolution",
  max_internal_iterations: 8,
  generator: { provider: "antfly", model: "test" },
  queries: [{ table: "runbooks", graph_navigation: navigation }],
};
void request;

const query: QueryRequest = {
  // @ts-expect-error Navigation is an agent strategy, not a canonical query field.
  graph_navigation: navigation,
};
void query;

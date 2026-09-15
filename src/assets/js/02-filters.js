// grafito frontend — filters
// Shared filter configuration (SHARED_FILTER_CONFIGS) consumed by
// // the search omnibox, the stats strip and the URL builder.

// --- Shared Configuration for Filters ---
const SHARED_FILTER_CONFIGS = [
  { id: "search-box", param: "q", type: "value" },
  { id: "unit-filter", param: "unit", type: "value" },
  { id: "tag-filter", param: "tag", type: "value" },
  { id: "hostname-filter", param: "hostname", type: "value" },
  { id: "time-range-filter", param: "since", type: "select" },
  { id: "priority-filter", param: "priority", type: "select" },
  {
    id: "live-view",
    param: "live-view",
    type: "checkbox",
    trueValue: "on",
  },
  {
    id: "col-visible-timestamp",
    param: "col-visible-timestamp",
    type: "checkbox",
    trueValue: "on",
  },
  {
    id: "col-visible-hostname",
    param: "col-visible-hostname",
    type: "checkbox",
    trueValue: "on",
  },
  {
    id: "col-visible-unit",
    param: "col-visible-unit",
    type: "checkbox",
    trueValue: "on",
  },
  {
    id: "col-visible-tag",
    param: "col-visible-tag",
    type: "checkbox",
    trueValue: "on",
  },
  {
    id: "col-visible-priority",
    param: "col-visible-priority",
    type: "checkbox",
    trueValue: "on",
  },
  {
    id: "col-visible-message",
    param: "col-visible-message",
    type: "checkbox",
    trueValue: "on",
  },
];

CodeMirror.defineSimpleMode("lot", {
  start: [
    {regex: /--.*/, token: "comment"},
    {regex: /[-+\/*=<>]+/, token: "operator"},
    {regex: /[a-zA-Z]+[0-9]+/, token: "variable-2"},
    {regex: /\d+/, token: "number"},
  ],
  meta: {
    lineComment: "//"
  }
});
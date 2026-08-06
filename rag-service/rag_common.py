"""Shared embedding conventions for indexer.py and rag_server.py.

Different embedding-model families expect different text prefixes for
asymmetric retrieval (query vs. passage). The prefixes apply ONLY to the
text fed to the encoder: indexed chunk text is stored (and BM25-searched)
unprefixed, and character spans always refer to the original document.
"""

import os
import re


def resolve_model_path(model_id, models_dir):
    """Prefer a locally saved copy of the model over the hub id.

    The controller saves each model to <models_dir>/<org>/<name> (a plain
    SentenceTransformer.save() directory — no hub-cache "models--" naming),
    which loads offline with no Hugging Face traffic. Fall back to the hub id
    when no local copy exists.
    """
    if models_dir:
        local = os.path.join(models_dir, model_id)
        if os.path.isfile(os.path.join(local, "modules.json")):
            return local
    return model_id


def embedding_prefixes(model_id):
    """Return (query_prefix, passage_prefix) for a model id.

    - BGE English v1.5 family: instruction prefix on the QUERY side only.
    - E5 family (incl. multilingual-e5-*): "query: " / "passage: " on both.
    - Everything else (MiniLM, ...): no prefixes.
    """
    mid = model_id.lower()
    if re.search(r"bge-(small|base|large)-en", mid):
        return "Represent this sentence for searching relevant passages: ", ""
    if re.search(r"(^|[^a-z0-9])e5($|[^a-z0-9])|e5-(small|base|large)", mid):
        return "query: ", "passage: "
    return "", ""

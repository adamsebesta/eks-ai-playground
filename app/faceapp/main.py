"""
Minimal face detection + recognition API on top of InsightFace.

Two endpoints:
  POST /enroll  - register a known face (name + image) into the enrolled set
  POST /detect  - run detection on a frame, match against enrolled faces

Enrolled embeddings persist to disk (expects a PVC mounted at /data in K8s)
so re-enrollment isn't needed every time the pod restarts.
"""
import io
import pickle
from pathlib import Path

import numpy as np
from fastapi import FastAPI, File, UploadFile, Form
from PIL import Image
import insightface

DATA_DIR = Path("/data")
ENROLLED_PATH = DATA_DIR / "enrolled.pkl"
MATCH_THRESHOLD = 0.5  # cosine similarity — tune against your own stock footage

app = FastAPI()

# buffalo_l: InsightFace's standard detection+recognition model pack.
# Downloads automatically on first run (~300MB) into ~/.insightface — bake
# this into the image at build time in production so pod startup isn't
# gated on a cold download every time.
face_model = insightface.app.FaceAnalysis(name="buffalo_l")
face_model.prepare(ctx_id=0)  # ctx_id=0 -> first GPU. -1 would force CPU.

DATA_DIR.mkdir(parents=True, exist_ok=True)
enrolled: dict[str, np.ndarray] = {}
if ENROLLED_PATH.exists():
    with open(ENROLLED_PATH, "rb") as f:
        enrolled = pickle.load(f)


def _load_image(raw: bytes) -> np.ndarray:
    img = Image.open(io.BytesIO(raw)).convert("RGB")
    return np.array(img)[:, :, ::-1]  # RGB -> BGR, what InsightFace expects


def _cosine_similarity(a: np.ndarray, b: np.ndarray) -> float:
    return float(np.dot(a, b) / (np.linalg.norm(a) * np.linalg.norm(b)))


@app.get("/")
def health():
    return {"status": "ok", "enrolled_count": len(enrolled)}


@app.post("/enroll")
async def enroll(name: str = Form(...), image: UploadFile = File(...)):
    img = _load_image(await image.read())
    faces = face_model.get(img)
    if not faces:
        return {"error": "no face detected in enrollment image"}
    if len(faces) > 1:
        return {"error": f"expected exactly 1 face, found {len(faces)} — use a cropped photo"}

    enrolled[name] = faces[0].normed_embedding
    with open(ENROLLED_PATH, "wb") as f:
        pickle.dump(enrolled, f)

    return {"enrolled": name, "total_enrolled": len(enrolled)}


@app.post("/detect")
async def detect(image: UploadFile = File(...)):
    img = _load_image(await image.read())
    faces = face_model.get(img)

    results = []
    for face in faces:
        best_match, best_score = "unknown", 0.0
        for name, embedding in enrolled.items():
            score = _cosine_similarity(face.normed_embedding, embedding)
            if score > best_score:
                best_match, best_score = name, score

        results.append({
            "bbox": face.bbox.tolist(),
            "match": best_match if best_score >= MATCH_THRESHOLD else "unknown",
            "confidence": round(best_score, 3),
        })

    return {"faces_detected": len(faces), "results": results}

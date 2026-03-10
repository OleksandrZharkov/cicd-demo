from flask import Flask, jsonify
import os

app = Flask(__name__)

VERSION = os.getenv("APP_VERSION", "1.0.0")

@app.route("/")
def home():
    return jsonify({
        "message": "Hello from CI/CD Demo! this is fvcking work ",
        "version": VERSION,
        "status": "ok"
    })

@app.route("/health")
def health():
    return jsonify({"status": "healthy"}), 200

if __name__ == "__main__":
    app.run(host="0.0.0.0", port=5000)

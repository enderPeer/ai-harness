@echo off
REM GLM-4.7-Flash on RTX 4080 — full GPU offload, 32k context, quantized KV cache
REM OpenAI-compatible API: http://127.0.0.1:8080/v1   Web UI: http://127.0.0.1:8080/
C:\llama.cpp\llama-server.exe -m C:\models\GLM-4.7-Flash-UD-Q3_K_XL.gguf -ngl 999 -c 32768 -np 1 -ctk q8_0 -ctv q8_0 --port 8080 --host 127.0.0.1

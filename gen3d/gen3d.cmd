@echo off
REM Image -> GLB on the local RTX 4080. Swaps out the GLM worker for VRAM,
REM runs Hunyuan3D shape generation, brings the worker back.
REM Usage: gen3d <input_image> <output.glb> [model_repo]
if "%~2"=="" ( echo usage: gen3d ^<input_image^> ^<output.glb^> [model_repo] & exit /b 2 )

echo [gen3d] pausing local GLM worker to free VRAM...
taskkill /im llama-server.exe /f >nul 2>&1
timeout /t 2 /nobreak >nul

C:\hy3d\venv\Scripts\python.exe C:\hy3d\gen3d.py %1 %2 %3
set RC=%ERRORLEVEL%

echo [gen3d] restarting local GLM worker...
start "glm-server" /min C:\llama.cpp\start-glm-server.cmd
exit /b %RC%

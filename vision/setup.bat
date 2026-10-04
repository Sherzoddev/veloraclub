@echo off
chcp 65001 >nul
cd /d "%~dp0"
if not exist venv (
  py -3 -m venv venv || goto :err
)
call venv\Scripts\activate.bat
python -m pip install --upgrade pip
python -m pip install -r requirements.txt || goto :err
if not exist .env copy .env.example .env
if not exist config.yaml copy config.example.yaml config.yaml
echo.
echo Готово. Теперь откройте файлы .env и config.yaml в Блокноте и заполните.
pause
exit /b 0
:err
echo.
echo Ошибка установки. Нужен Python 3.11 или 3.12 с python.org (галочка Add python.exe to PATH).
pause
exit /b 1

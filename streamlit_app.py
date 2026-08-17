"""
Network Device Monitor & Diagnostic Tool - Streamlit Entrypoint
system/streamlit_app.py を呼び出すエントリポイント
"""
import os
import sys

# Add system folder to path and execute the main application
system_dir = os.path.join(os.path.dirname(os.path.abspath(__file__)), "system")
if system_dir not in sys.path:
    sys.path.insert(0, system_dir)

# Execute system/streamlit_app.py directly in current namespace
app_path = os.path.join(system_dir, "streamlit_app.py")
with open(app_path, "r", encoding="utf-8") as f:
    code = f.read()

exec(compile(code, app_path, "exec"))

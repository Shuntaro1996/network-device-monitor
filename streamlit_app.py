"""
Streamlit Community Cloud Entry Point Wrapper
Automatically executes system/streamlit_app.py
"""
import os
import runpy

app_path = os.path.join(os.path.dirname(__file__), "system", "streamlit_app.py")
if os.path.exists(app_path):
    runpy.run_path(app_path, run_name="__main__")
else:
    import streamlit as st
    st.error(f"Error: Could not locate {app_path}")

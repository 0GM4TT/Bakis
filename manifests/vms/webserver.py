#!/usr/bin/env python3
"""
Dynamic web server for KubeVirt VM.
Shows current Pi node the VM is running on by querying Prometheus.
"""

import http.server
import urllib.request
import json
import os

PROMETHEUS_URL = "http://192.168.1.155:30091"
VM_NAME = os.environ.get("VM_NAME", "unknown")

def get_current_node():
    try:
        # Step 1: Find running pod for this VM
        url = f"{PROMETHEUS_URL}/api/v1/query?query=kube_pod_status_phase"
        data = json.loads(urllib.request.urlopen(url, timeout=3).read())
        
        running_pod = None
        for r in data['data']['result']:
            pod = r['metric'].get('pod', '')
            phase = r['metric'].get('phase', '')
            value = r['value'][1]
            if VM_NAME in pod and phase == 'Running' and value == '1':
                running_pod = pod
                break
        
        if not running_pod:
            return 'unknown'

        # Step 2: Get node for that pod
        url = f"{PROMETHEUS_URL}/api/v1/query?query=kube_pod_info"
        data = json.loads(urllib.request.urlopen(url, timeout=3).read())
        
        for r in data['data']['result']:
            if r['metric'].get('pod') == running_pod:
                return r['metric'].get('node', 'unknown')

    except Exception as e:
        return f'error: {e}'
    
    return 'unknown'


class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        node = get_current_node()
        
        html = f"""<!DOCTYPE html>
<html>
<head>
    <title>{VM_NAME}</title>
    <meta http-equiv="refresh" content="5">
    <style>
        body {{
            font-family: Arial, sans-serif;
            display: flex;
            justify-content: center;
            align-items: center;
            height: 100vh;
            margin: 0;
            background: #f0f0f0;
        }}
        .card {{
            background: white;
            padding: 40px;
            border-radius: 10px;
            box-shadow: 0 2px 10px rgba(0,0,0,0.1);
            text-align: center;
        }}
        h1 {{ color: #333; }}
        .node {{ 
            font-size: 24px; 
            color: #0066cc;
            font-weight: bold;
            margin: 20px 0;
        }}
        .refresh {{ 
            font-size: 12px; 
            color: #999;
        }}
    </style>
</head>
<body>
    <div class="card">
        <h1>Hello from {VM_NAME}</h1>
        <p>Currently running on:</p>
        <div class="node">{node}</div>
        <p class="refresh">Page auto-refreshes every 5 seconds</p>
    </div>
</body>
</html>"""

        self.send_response(200)
        self.send_header('Content-type', 'text/html')
        self.end_headers()
        self.wfile.write(html.encode())

    def log_message(self, format, *args):
        pass  # Suppress access logs


if __name__ == '__main__':
    server = http.server.HTTPServer(('0.0.0.0', 80), Handler)
    print(f"Starting web server for {VM_NAME} on port 80")
    server.serve_forever()

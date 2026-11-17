import json, subprocess, sys, urllib.request, urllib.error, concurrent.futures, time, socket
opener=urllib.request.build_opener(urllib.request.ProxyHandler({}))
p=subprocess.Popen([sys.argv[1]], stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)
try:
 state=json.loads(p.stdout.readline()); assert state['state']=='ready', state['message']
 port=state['addresses'][0].rsplit(':',1)[1]; base='http://127.0.0.1:'+port
 token=state['token']; pin=state['pin']
 def request(path,body=None,auth=True,origin=None,host=None):
  headers={'Authorization':'Bearer '+(token if auth else 'invalid'),'Content-Type':'application/json'}
  if body is not None: headers['Origin']=base if origin is None else origin
  if host: headers['Host']=host
  req=urllib.request.Request(base+path,data=None if body is None else json.dumps(body).encode(),headers=headers)
  try:
   with opener.open(req,timeout=5) as r: return r.status,r.read()
  except urllib.error.HTTPError as e: return e.code,e.read()
 assert request('/')[0]==200
 assert request('/health')[0]==200
 assert request('/health',auth=False)[0]==401
 badhost=request('/health',host='evil.test:'+port); assert badhost[0]==403, ('badhost',badhost)
 assert request('/pair',{'pin':pin},origin='http://evil.test')[0]==403
 assert request('/pair',{'pin':'bad'})[0]==401
 assert json.loads(request('/pair',{'pin':pin})[1])['token']==token
 assert request('/turn',{'direction':'delete','id':'bad'})[0]==400
 assert request('/turn',{'direction':'next','id':123})[0]==400
 first=request('/turn',{'direction':'next','id':'one'});assert first[0]==200
 assert first==request('/turn',{'direction':'next','id':'one'})
 assert request('/turn',{'direction':'prev','id':'one'})[0]==409
 with concurrent.futures.ThreadPoolExecutor(2) as pool:
  f=pool.submit(request,'/turn',{'direction':'prev','id':'two'});time.sleep(.05)
  assert request('/turn',{'direction':'next','id':'three'})[0]==409
  assert json.loads(f.result()[1])['message']=='mock-2-prev'
 for _ in range(9): assert request('/pair',{'pin':'bad'})[0]==401
 assert request('/pair',{'pin':pin})[0]==429
 # Duplicate length headers and chunked request bodies are not accepted.
 for extra in ['Content-Length: 2\r\nContent-Length: 2','Transfer-Encoding: chunked']:
  with socket.create_connection(('127.0.0.1',int(port)),timeout=3) as s:
   s.sendall(('POST /turn HTTP/1.1\r\nHost: 127.0.0.1:'+port+'\r\n'+extra+'\r\n\r\n{}').encode())
   assert s.recv(4096).startswith(b'HTTP/1.1 400')
 p.stdin.write('stop\n');p.stdin.flush();stopped=json.loads(p.stdout.readline())
 assert stopped['state']=='stopped' and not stopped['token'] and not stopped['pin']
 p.stdin.write('start\n');p.stdin.flush();p.stdout.readline()
 time.sleep(.3);p.stdin.write('status\n');p.stdin.flush();fresh=json.loads(p.stdout.readline())
 assert fresh['state']=='ready' and fresh['token']!=token
 p.stdin.write('pause\n');p.stdin.flush();assert p.stdout.readline().strip()=='paused'
 time.sleep(15);p.stdin.write('status\n');p.stdin.flush();assert json.loads(p.stdout.readline())['state']=='stopped'
 print('PASS: native HTTP pairing/authentication/origin/host/validation/deduplication/busy/rate-limit/framing/stop/rekey; no real key events')
finally:
 p.terminate();p.wait(timeout=5)

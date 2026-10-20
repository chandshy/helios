from pathlib import Path
import hashlib
import json
import subprocess
import resource

resource.setrlimit(resource.RLIMIT_CORE, (0, 0))

import argparse
import os

parser = argparse.ArgumentParser()
parser.add_argument('--candidate', required=True, type=Path)
parser.add_argument('--original', required=True, type=Path)
parser.add_argument('--output', required=True, type=Path)
args = parser.parse_args()
O = args.output.resolve()
assert not O.exists(), 'output must be a fresh owned directory'
O.mkdir(parents=True)
assert hashlib.sha256(args.candidate.read_bytes()).hexdigest() == '574b4b898ba6c492da326879e74fd3e9fd13196d7320cd85a54e2c6c598dcd52'
assert hashlib.sha256(args.original.read_bytes()).hexdigest() == '05227608fc5963992b67f3bfd645fb194a181778a5c10fcccdcbfe3d62bb5396' 
prefix = r'''
#include <atomic>
#include <cassert>
#include <condition_variable>
#include <cstdlib>
#include <functional>
#include <iostream>
#include <mutex>
#include <sstream>
#include <stdexcept>
#include <string>
#include <thread>
#include <vector>
using VkResult=int;
using VkSemaphore=unsigned long;
constexpr int VK_SUCCESS=0;
constexpr int VK_STRUCTURE_TYPE_SEMAPHORE_TYPE_CREATE_INFO=1;
constexpr int VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO=2;
constexpr int VK_SEMAPHORE_TYPE_TIMELINE=3;
struct VkSemaphoreTypeCreateInfo {int sType;const void*pNext=nullptr;int semaphoreType=0;};
struct VkSemaphoreCreateInfo {int sType;const void*pNext;};
static std::atomic<int> workers{0}, waiting{0};
static int threadAttempts=0,failThread=0;
namespace str {
 template<typename... T> std::string format(T... xs){std::ostringstream s;(s<<...<<xs);return s.str();}
}
struct FakeVk {
 int result[2];int calls=0;std::vector<VkSemaphore> destroyed;
 int device(){return 1;}
 VkResult vkCreateSemaphore(int,const VkSemaphoreCreateInfo*,void*,VkSemaphore*out){int index=calls++;int r=result[index];if(!r)*out=index+1;return r;}
 void vkDestroySemaphore(int,VkSemaphore value,void*){assert(value==1||value==2);for(auto old:destroyed)assert(old!=value);destroyed.push_back(value);}
};
struct DxvkDevice {FakeVk vk;void*getCheckpointBuffer(){return nullptr;} FakeVk*vkd(){return &vk;}};
namespace dxvk {
using mutex=std::mutex;
class thread : public std::thread {
public:
 thread()=default;
 template<class F> explicit thread(F proc){
  int attempt=++threadAttempts;
  if(failThread==attempt){
   if(attempt==2)while(waiting.load()!=1)std::this_thread::yield();
   throw std::runtime_error("thread creation failure"+std::to_string(attempt));
  }
  std::thread::operator=(std::thread(std::move(proc)));
 }
 thread(thread&&)=default;
 thread& operator=(thread&&)=default;
};
using DxvkQueueCallback=std::function<void()>;
using DxvkError=std::runtime_error;
class DxvkSubmissionQueue {
public:
 DxvkSubmissionQueue(DxvkDevice*,const DxvkQueueCallback&);
 ~DxvkSubmissionQueue();
private:
 DxvkDevice*m_device;
 void*m_checkpoints;
 DxvkQueueCallback m_callback;
 struct {VkSemaphore graphics=0,transfer=0;} m_semaphores;
 std::atomic<bool>m_stopped{false};
 mutex m_mutex;
 std::condition_variable m_appendCond,m_submitCond;
 thread m_submitThread,m_finishThread;
 void submitCmdLists(){if(CHECK_INIT_ORDER)assert(m_device->vk.calls==2&&m_device->vk.result[0]==0&&m_device->vk.result[1]==0);workers++;std::unique_lock<mutex>lock(m_mutex);waiting++;m_appendCond.wait(lock,[this]{return m_stopped.load();});waiting--;workers--;}
 void finishCmdLists(){if(CHECK_INIT_ORDER)assert(m_device->vk.calls==2&&m_device->vk.result[0]==0&&m_device->vk.result[1]==0);workers++;std::unique_lock<mutex>lock(m_mutex);waiting++;m_submitCond.wait(lock,[this]{return m_stopped.load();});waiting--;workers--;}
};
'''
suffix = r'''
}
int main(int argc,char**argv){
 assert(argc==4);std::set_terminate([]{std::_Exit(86);});
 int g=std::stoi(argv[1]),t=std::stoi(argv[2]);failThread=std::stoi(argv[3]);
 for(int iteration=0;iteration<25;iteration++){
  threadAttempts=0;DxvkDevice device{{{g,t},0,{}}};bool caught=false;std::string message;
  try{dxvk::DxvkSubmissionQueue queue(&device,[]{});while(waiting.load()!=2)std::this_thread::yield();}catch(const std::exception&e){caught=true;message=e.what();}
  assert(caught==(g!=0||t!=0||failThread!=0));assert(workers.load()==0&&waiting.load()==0);assert(device.vk.calls==2);
  assert(device.vk.destroyed.size()==size_t((g==0)+(t==0)));
  for(auto handle:device.vk.destroyed)assert((handle==1&&g==0)||(handle==2&&t==0));
  if(g||t){std::string expected="graphics="+std::to_string(g)+", transfer="+std::to_string(t);assert(message.find(expected)!=std::string::npos);assert(threadAttempts==0);}
  else if(failThread){assert(message=="thread creation failure"+std::to_string(failThread));assert(threadAttempts==failThread);}
 }
 std::cout<<"25 actual-constructor/destructor iterations passed; initialization, partial-thread cleanup, handles and original errors verified\n";
}
'''
def bodies(source):
 start=source.index('  DxvkSubmissionQueue::DxvkSubmissionQueue(')
 end=source.index('  void DxvkSubmissionQueue::submit(')
 return source[start:end]


results=[]
def build_run(name,source,cases,original=False,mutant=False):
 cpp=O/(name+'-unwind-test.cpp');cpp.write_text(prefix+bodies(source)+suffix);exe=O/(name+'-unwind-test')
 c=subprocess.run(['c++','-std=c++17','-O2','-pthread','-Wall','-Wextra','-Werror','-Wno-missing-field-initializers','-DCHECK_INIT_ORDER='+('0' if original else '1'),str(cpp),'-o',str(exe)],capture_output=True,text=True);assert c.returncode==0,c.stderr
 for g,t,f in cases:
  try:
   run=subprocess.run([str(exe),str(g),str(t),str(f)],capture_output=True,text=True,timeout=2)
   expected=86 if original else 0
   result={'source':name,'sourceSha256':hashlib.sha256(source.encode()).hexdigest(),'graphicsResult':g,'transferResult':t,'failWorkerCreation':f,'actualExit':run.returncode,'expectedExit':expected,'stdout':run.stdout,'stderr':run.stderr,'passed':run.returncode!=0 if mutant else run.returncode==expected}
  except subprocess.TimeoutExpired:
   result={'source':name,'graphicsResult':g,'transferResult':t,'failWorkerCreation':f,'timeoutSeconds':2,'passed':mutant and name.startswith('missing-')}
  results.append(result)
candidate=args.candidate.read_text();original=args.original.read_text()
build_run('candidate',candidate,[(-1,0,0),(0,-2,0),(-1,-2,0),(0,0,0),(0,0,1),(0,0,2)])
build_run('original',original,[(-1,0,0),(0,-2,0),(-1,-2,0),(0,0,2)],original=True)
mutants={
 'missing-append-wakeup':(candidate.replace('m_appendCond.notify_all();',''),[(0,0,0)]),
 'missing-submit-wakeup':(candidate.replace('m_submitCond.notify_all();',''),[(0,0,0)]),
 'destroy-failed-handle':(candidate.replace('if (!vrGraphics)','if (vrGraphics)',1),[(-1,0,0)]),
 'missing-partial-worker-join':(candidate.replace('      if (m_submitThread.joinable())\n        m_submitThread.join();','',1),[(0,0,2)]),
 'zero-error-diagnostic':(candidate.replace('vrGraphics, ", transfer=", vrTransfer','0, ", transfer=", 0',1),[(-1,0,0)]),
}
for name,(source,cases) in mutants.items():
 assert source!=candidate;build_run(name,source,cases,mutant=True)
report={'passed':all(r['passed'] for r in results),'candidateCases':6,'iterationsPerCandidateCase':25,'originalNegativeControls':4,'adverseMutants':5,'workersParkedBeforeDestructor':True,'firstWorkerParkedBeforeSecondCreationFailure':True,'cases':results,'consumer':'Unmodified extracted candidate constructor+destructor; real host threads/condition variables, mocked Vulkan device and injectable thread-constructor wrapper. Actual retained Win32 thread destructor also terminates when joinable.','limits':['No WindowsDLL/realVulkan/actualWin32thread-wrapper or guest execution.','Worker GPU bodies modeled as actual stop-predicate waits; native scheduler/GPU integration unverified.','C++/Vulkan initialization and first/second thread-creation failure cleanup covered; this does not prove B cause or B working.']}
(O/'proof.json').write_text(json.dumps(report,indent=2)+'\n');assert report['passed'];print('Six candidate cases, four original controls and five mutants passed')
if os.environ.get('GITHUB_OUTPUT'):
    with open(os.environ['GITHUB_OUTPUT'], 'a', encoding='utf-8') as output:
        output.write('candidate_sha=574b4b898ba6c492da326879e74fd3e9fd13196d7320cd85a54e2c6c598dcd52\n')

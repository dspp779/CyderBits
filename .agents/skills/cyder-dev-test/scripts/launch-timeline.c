// launch-timeline ROOTPID SECONDS
// Every 50 ms, record each descendant of ROOTPID (normally the running
// CyderSwift) with its kernel start time. On exit, print one line per process:
// start offset (s), lifetime (s), pid, ppid, argv. Sort by the first column.
// Build: clang -O1 -o /tmp/launch-timeline launch-timeline.c
#include <libproc.h>
#include <sys/sysctl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/time.h>
#define MAXP 8192
typedef struct { int pid, ppid; double start, last; char cmd[220]; } rec;
static rec recs[MAXP]; static int nrec;
static double now(void){ struct timeval t; gettimeofday(&t,0); return t.tv_sec+t.tv_usec/1e6; }
static void args(int pid, char *out, size_t n){
  int mib[3]={CTL_KERN,KERN_PROCARGS2,pid}; static char buf[65536]; size_t sz=sizeof buf; out[0]=0;
  if(sysctl(mib,3,buf,&sz,0,0)) return; int argc; memcpy(&argc,buf,4); char *p=buf+4;
  while(p<buf+sz && *p) p++; while(p<buf+sz && !*p) p++;
  size_t o=0; for(int i=0;i<argc && p<buf+sz && o<n-2;i++){ size_t l=strlen(p); 
    const char *s=p; const char *c=strstr(s,"Cyder.app/Contents/"); if(c) s=c+19;
    o+=snprintf(out+o,n-o,"%s%.*s",i?" ":"",(int)(l-(s-p)>90?90:l-(s-p)),s); p+=l+1; }
}
int main(int ac,char**av){
  if(ac!=3){ fprintf(stderr,"usage: %s ROOTPID SECONDS\n",av[0]); return 2; }
  int root=atoi(av[1]); double secs=atof(av[2]), t0=now();
  static int pids[MAXP], pp[MAXP], pidv[MAXP];
  while(now()-t0<secs){
    int n=proc_listallpids(pids,sizeof pids);  /* returns a count */
    struct proc_bsdinfo bi;
    int cnt=0;
    for(int i=0;i<n && i<MAXP;i++){ if(proc_pidinfo(pids[i],PROC_PIDTBSDINFO,0,&bi,sizeof bi)==sizeof bi){ pidv[cnt]=pids[i]; pp[cnt]=bi.pbi_ppid; cnt++; } }
    // descendants
    static char in[MAXP]; memset(in,0,sizeof in); int changed=1;
    while(changed){ changed=0; for(int i=0;i<cnt;i++){ if(in[i]) continue; if(pp[i]==root){in[i]=1;changed=1;continue;} for(int j=0;j<cnt;j++) if(in[j]&&pidv[j]==pp[i]){in[i]=1;changed=1;break;} } }
    double t=now();
    for(int i=0;i<cnt;i++) if(in[i]){
      int k=-1; for(int r=0;r<nrec;r++) if(recs[r].pid==pidv[i]){k=r;break;}
      if(k<0 && nrec<MAXP){ k=nrec++; recs[k].pid=pidv[i]; recs[k].ppid=pp[i];
        proc_pidinfo(pidv[i],PROC_PIDTBSDINFO,0,&bi,sizeof bi); recs[k].start=bi.pbi_start_tvsec+bi.pbi_start_tvusec/1e6;
        args(pidv[i],recs[k].cmd,sizeof recs[k].cmd); }
      if(k>=0) recs[k].last=t;
    }
    usleep(50000);
  }
  for(int r=0;r<nrec;r++) printf("%7.2f %6.2f %6d %6d %s\n",recs[r].start-t0,recs[r].last-recs[r].start,recs[r].pid,recs[r].ppid,recs[r].cmd);
  return 0;
}

import {WidgetType} from '@codemirror/view';
import DOMPurify from 'dompurify';

let loading, running=false, sequence=0, runtimeTheme;
const pending=new Map(), owners=new Set(), cache=new Map();
let cacheBytes=0;
const label=key=>window.DuckpadEditorLabels?.[key]||'';

function runtime() {
  if(window.duckpadMermaid)return Promise.resolve(window.duckpadMermaid);
  if(!loading)loading=new Promise((resolve,reject)=>{
    const script=document.createElement('script');script.src='duckpad-editor://assets/mermaid.js';
    script.onload=()=>resolve(window.duckpadMermaid);
    script.onerror=()=>{loading=undefined;script.remove();reject(new Error('Diagram runtime unavailable'));};
    document.head.append(script);
  });
  return loading;
}

function remember(key,svg,owner) {
  const bytes=(key.length+svg.length)*2;if(bytes>4*1024*1024)return;
  if(cache.has(key)){cacheBytes-=cache.get(key).bytes;cache.delete(key);}
  while(cache.size&&(cache.size>=16||cacheBytes+bytes>4*1024*1024)) {
    const oldest=cache.keys().next().value;cacheBytes-=cache.get(oldest).bytes;cache.delete(oldest);
  }
  cache.set(key,{svg,owner,bytes});cacheBytes+=bytes;
}

async function drain() {
  if(running)return;
  running=true;
  try {
    while(pending.size) {
      const [controller,request]=pending.entries().next().value;pending.delete(controller);
      if(!controller.current(request))continue;
      try {
        const key=request.themeKey+'\0'+request.source,cached=cache.get(key);
        // An SVG's IDs may be reused only after its previous owner has gone.
        // Identical diagrams visible together receive independent Mermaid IDs.
        let svg=cached&&(cached.owner===controller.id||!owners.has(cached.owner))?cached.svg:undefined;
        if(!svg) {
          const mermaid=await runtime();if(!controller.current(request))continue;
          if(runtimeTheme!==request.themeKey) {
            mermaid.initialize({startOnLoad:false,securityLevel:'strict',htmlLabels:false,theme:'base',
              themeVariables:{darkMode:request.theme==='dark',background:request.colors.bg,
                primaryColor:request.colors.code,primaryTextColor:request.colors.fg,primaryBorderColor:request.colors.border,
                secondaryColor:request.colors.bg,secondaryTextColor:request.colors.fg,secondaryBorderColor:request.colors.border,
                tertiaryColor:request.colors.code,tertiaryTextColor:request.colors.fg,tertiaryBorderColor:request.colors.border,
                lineColor:request.colors.muted,textColor:request.colors.fg,edgeLabelBackground:request.colors.bg,
                nodeBkg:request.colors.code,nodeTextColor:request.colors.fg,nodeBorder:request.colors.border,
                clusterBkg:request.colors.bg,clusterBorder:request.colors.border},
              suppressErrorRendering:true,secure:['secure','securityLevel','startOnLoad','htmlLabels','suppressErrorRendering']});
            runtimeTheme=request.themeKey;
          }
          const result=await mermaid.render('duckpad-live-diagram-'+(++sequence),request.source);
          if(!controller.current(request))continue;
          svg=DOMPurify.sanitize(result.svg,{USE_PROFILES:{svg:true,svgFilters:true,html:true},
            FORBID_TAGS:['script','iframe','object','embed','form','input']});
        }
        if(!controller.current(request))continue;
        remember(key,svg,controller.id);controller.show(svg);
      } catch {if(controller.current(request))controller.failed();}
    }
  } finally {running=false;}
}

class DiagramController {
  constructor(view,widget) {
    this.view=view;this.id=++sequence;owners.add(this.id);this.version=0;
    this.root=document.createElement('div');this.root.className='md-diagram';
    this.root.setAttribute('role','group');
    const header=document.createElement('div');header.className='md-diagram-header';
    const name=document.createElement('span');name.textContent='mermaid';
    this.edit=document.createElement('button');this.edit.type='button';this.edit.textContent='‹/›';
    this.edit.addEventListener('mousedown',event=>event.preventDefault());
    this.edit.addEventListener('click',()=>this.reveal());
    header.append(name,this.edit);
    this.content=document.createElement('div');this.content.className='md-diagram-content';
    this.content.addEventListener('mousedown',event=>{event.preventDefault();this.reveal();});
    this.status=document.createElement('div');this.status.className='md-diagram-status';
    this.status.setAttribute('aria-live','polite');
    this.root.append(header,this.content,this.status);this.update(widget);
  }
  reveal() {
    this.view.dispatch({selection:{anchor:this.view.posAtDOM(this.root)+(this.widget.position-this.widget.anchor)},scrollIntoView:true});this.view.focus();
  }
  update(widget) {
    const changed=!this.widget||this.widget.source!==widget.source||this.widget.themeKey!==widget.themeKey;
    this.widget=widget;this.root.classList.toggle('is-editing',widget.editing);
    this.root.setAttribute('aria-label',label('mermaidDiagram'));
    this.edit.title=label('editSource');this.edit.setAttribute('aria-label',label('editSource'));
    if(!changed)return;
    clearTimeout(this.timer);this.version++;
    this.status.textContent=label('renderingDiagram');this.root.dataset.state='pending';
    const request={source:widget.source,theme:widget.theme,themeKey:widget.themeKey,colors:widget.colors,version:this.version};
    this.timer=setTimeout(()=>{pending.set(this,request);void drain();},cache.has(widget.themeKey+'\0'+widget.source)?0:300);
  }
  current(request) {return !this.disposed&&this.root.isConnected&&this.version===request.version;}
  show(svg) {
    this.content.innerHTML=svg;this.root.dataset.state='ready';this.status.textContent='';this.view.requestMeasure();
  }
  failed() {
    this.root.dataset.state='invalid';this.status.textContent=label('invalidDiagram');
    if(!this.content.querySelector('svg')) {
      const source=document.createElement('pre');source.textContent=this.widget.source;this.content.replaceChildren(source);
    }
    this.view.requestMeasure();
  }
  destroy() {this.disposed=true;clearTimeout(this.timer);pending.delete(this);owners.delete(this.id);}
}

export class DiagramPreview extends WidgetType {
  constructor(source,position,editing,anchor) {
    super();Object.assign(this,{source,position,editing,anchor});this.theme=/dark/i.test(document.body.dataset.theme)?'dark':'default';
    this.colors=window.DuckpadEditorColors||{};this.themeKey=JSON.stringify([this.theme,this.colors]);
    this.labels=window.DuckpadEditorLabels;
  }
  eq(other) {return this.source===other.source&&this.position===other.position&&this.anchor===other.anchor&&this.editing===other.editing&&this.themeKey===other.themeKey&&this.labels===other.labels;}
  toDOM(view) {const controller=new DiagramController(view,this);controller.root.diagramController=controller;return controller.root;}
  updateDOM(dom) {dom.diagramController.update(this);return true;}
  destroy(dom) {dom.diagramController.destroy();}
  ignoreEvent() {return true;}
}

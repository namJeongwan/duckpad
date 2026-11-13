// CodeMirror measures the widget root's border box. Contain child margins so
// rendered spacing also contributes to its height map and pointer coordinates.
export function blockWidget(content) {
  const root=document.createElement('div');
  root.className='md-block-widget';
  root.append(content);
  return root;
}

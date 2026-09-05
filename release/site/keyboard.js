function renderKeyboard(svg, model) {
  const air65 = [
    [['', 1, 'mint'], '1', '2', '3', '4', '5', '6', '7', '8', '9', '0', '−', '=', ['BACKSPACE', 2], ['', 1, 'knob']],
    [['TAB', 1.5], 'Q', 'W', 'E', 'R', 'T', 'Y', 'U', 'I', 'O', 'P', '[', ']', ['\\', 1.5], ['', 1, 'yellow']],
    [['CAPS', 1.75], 'A', 'S', 'D', 'F', 'G', 'H', 'J', 'K', 'L', ';', "'", ['ENTER', 2.25], 'HOME'],
    [['SHIFT', 2.25], 'Z', 'X', 'C', 'V', 'B', 'N', 'M', ',', '.', '/', ['SHIFT', 1.75], '↑', 'END'],
    [['CTRL', 1.25], ['OPT', 1.25], ['CMD', 1.25], ['', 6.25], 'CMD', 'FN', 'CTRL', '←', '↓', '→']
  ];
  let keys = model.keys;
  // Match the App's hand-tuned Air and Kick illustrations; other layouts use its catalog.
  if (['Air65V3', 'Air75V3', 'Kick75', 'Kick75High'].includes(model.sourceModel)) {
    let rows = air65;
    if (model.sourceModel === 'Air75V3') {
      air65[0][0] = '~'; air65[0][14] = 'PGUP'; air65[1][14] = 'PGDN';
      rows = [[['', 1, 'mint'], ...Array.from({ length: 12 }, (_, i) => `F${i + 1}`), '♫', ['', 1, 'yellow'], ['', 1, 'knob']], ...air65];
    } else if (model.sourceModel.startsWith('Kick')) {
      const spacer = ['', .25, 'spacer'];
      const top = [['ESC', 1, 'mint'], spacer];
      for (let group = 0; group < 3; group++) top.push(...Array.from({ length: 4 }, (_, i) => `F${group * 4 + i + 1}`), spacer);
      top.push(['DEL', 1, 'yellow'], spacer, ['', 1, 'knob']);
      air65[0][0] = '~';
      ['HOME', 'PGUP', 'PGDN'].forEach((label, i) => air65[i].splice(-1, 1, spacer, label));
      air65[3].splice(-1, 1, spacer, ['', 1, 'spacer']);
      air65[4] = [['CTRL', 1.25], ['OPT', 1.25], ['CMD', 1.25], ['', 6.25], ['CMD', 1.25], ['FN', 1.25], ['', .5, 'spacer'], '←', '↓', spacer, '→'];
      rows = [top, ...air65];
    }
    keys = rows.flatMap((row, y) => {
      let x = 0;
      return row.map(item => {
        const [label, width = 1, surface = 'standard'] = Array.isArray(item) ? item : [item];
        const key = { label, x, y: y * 1.1, width, height: 1, shape: surface, accent: surface === 'mint' };
        x += width;
        return key;
      });
    });
  }
  const width = Math.max(...keys.map(key => key.x + key.width)) + 1.2;
  const height = Math.max(...keys.map(key => key.y + key.height)) + 1.2;
  const unit = 48;
  svg.replaceChildren();
  svg.setAttribute('viewBox', `0 0 ${width * unit} ${height * unit + 6}`);
  svg.dataset.model = model.sourceModel;
  function element(name, attributes, text, parent = svg) {
    const node = document.createElementNS('http://www.w3.org/2000/svg', name);
    for (const [key, value] of Object.entries(attributes)) node.setAttribute(key, value);
    if (text !== undefined) node.textContent = text;
    parent.append(node);
    return node;
  }
  element('rect', { x: 0, y: 6, width: width * unit, height: height * unit, rx: 30, fill: '#bfc3c9' });
  element('rect', { x: 0, y: 0, width: width * unit, height: height * unit, rx: 30, fill: '#d4d7dc', stroke: '#e9ebee', 'stroke-width': 2 });
  for (const key of keys) {
    if (key.shape === 'spacer') continue;
    const x = (key.x + .6) * unit;
    const y = (key.y + .6) * unit;
    const w = key.width * unit - 5;
    const h = key.height * unit - 5;
    if (key.shape === 'knob') {
      const radius = Math.min(w, h) / 2 - 2;
      element('circle', { cx: x + w / 2, cy: y + h / 2, r: radius, fill: '#d75b44', stroke: '#a84738', 'stroke-width': 3 });
      element('path', { d: `M${x + w / 2 - 5},${y + h / 2 + 6} l10,-12`, stroke: '#76362b', 'stroke-width': 3, 'stroke-linecap': 'round' });
      continue;
    }
    const iso = key.shape === 'isoEnter';
    const shape = iso ? 'path' : 'rect';
    const geometry = iso ? { d: `M${x},${y} h${w} v${h} h${-w + unit * .25} V${y + unit} H${x} Z` } : { x, y, width: w, height: h, rx: 7 };
    element(shape, { ...geometry, transform: 'translate(0 3)', fill: '#aeb3bb' });
    element(shape, { ...geometry, class: `key-base${key.accent ? ' key-mint' : key.shape === 'yellow' ? ' key-yellow' : ''}` });
    element(shape, { ...geometry, class: 'key-tint' });
    const inset = iso ? unit * .25 : 0;
    element('rect', { x: x + inset + 5, y: y + h - 5, width: w - inset - 10, height: 3, rx: 1.5, class: 'key-light' });
    const lines = key.label.split('\n');
    const fontSize = Math.min(12, (w - 5) / (Math.max(...lines.map(line => line.length), 1) * .68));
    const label = element('text', { x: x + w / 2, y: y + h / 2, class: 'key-label', style: `font-size:${fontSize}px` });
    lines.forEach((line, i) => element('tspan', { x: x + w / 2, y: y + h / 2 + (i - (lines.length - 1) / 2) * fontSize * 1.1 }, line, label));
  }
}

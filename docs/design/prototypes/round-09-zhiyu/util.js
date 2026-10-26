const paths={
 layers:'M12 3 3 8l9 5 9-5-9-5ZM3 12l9 5 9-5M3 16l9 5 9-5',
 grid:'M3 3h7v7H3zM14 3h7v7h-7zM3 14h7v7H3zM14 14h7v7h-7z',
 server:'M4 3h16v7H4zM4 14h16v7H4zM7 6.5h.01M7 17.5h.01M11 6.5h6M11 17.5h6',
 user:'M16 7a4 4 0 1 1-8 0 4 4 0 0 1 8 0ZM4 21v-3a8 6 0 0 1 16 0v3',
 book:'M3 4h6a3 3 0 0 1 3 3v14a4 4 0 0 0-4-2H3V4Zm18 0h-6a3 3 0 0 0-3 3v14a4 4 0 0 1 4-2h5V4Z',
 file:'M5 2h9l5 5v15H5V2Zm9 0v6h5M8 12h8M8 16h6',
 briefcase:'M8 6V3h8v3M3 6h18v14H3V6Zm0 6c6 3 12 3 18 0M10 12h4',
 key:'M14 7a5 5 0 1 1-10 0 5 5 0 0 1 10 0Zm-1 4 8 8m-5-5 3-3m0 6 3-3',
 search:'M17 10a7 7 0 1 1-14 0 7 7 0 0 1 14 0Zm-2 5 6 6',
 chevron:'m9 5 7 7-7 7',down:'m6 9 6 6 6-6',plus:'M12 4v16M4 12h16',
 x:'m6 6 12 12M6 18 18 6',arrow:'M5 12h14m-6-6 6 6-6 6',back:'M19 12H5m6-6-6 6 6 6',
 shield:'M12 2 3 6v6c0 5 9 10 9 10s9-5 9-10V6l-9-4Zm-4 9 3 3 5-6',
 inbox:'M3 4h18v16H3V4Zm0 10h5l2 3h4l2-3h5',clock:'M22 12a10 10 0 1 1-20 0 10 10 0 0 1 20 0ZM12 6v6l4 3',
 send:'m22 2-7 20-4-9L2 9l20-7ZM11 13 22 2',
 link:'m9 15 6-6M10 7l2-2a5 5 0 0 1 7 7l-2 2M14 17l-2 2a5 5 0 0 1-7-7l2-2',
 folder:'M3 5h7l2 3h9v13H3V5Z',check:'m4 12 5 5L20 6',info:'M12 16v-4m0-4h.01M22 12a10 10 0 1 1-20 0 10 10 0 0 1 20 0Z',
 expand:'M8 3H3v5m13-5h5v5M3 16v5h5m13-5v5h-5',sliders:'M3 6h4m4 0h10M3 18h10m4 0h4M7 3v6m6 6v6M3 12h18',
 mail:'M3 4h18v16H3V4Zm0 1 9 8 9-8',star:'m12 2 3 6 7 1-5 5 1 7-6-3-6 3 1-7-5-5 7-1 3-6'
};
const icon=(n,extra='')=>'<svg class="icon '+extra+'" viewBox="0 0 24 24" aria-hidden="true"><path d="'+(paths[n]||paths.file)+'"/></svg>';
const e=s=>String(s??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));

// Render real app captures in Marracat's App Store marketing layout.
// Requires the repository's Playwright dependency and installed Google Chrome.
const {chromium}=require('../../web/node_modules/playwright');
const fs=require('fs');const path=require('path');
const root=path.resolve(__dirname,'../..');
const image=p=>'data:image/png;base64,'+fs.readFileSync(path.join(root,p)).toString('base64');
const source=name=>image(fs.existsSync(path.join(__dirname,'sources',name+'.png'))?`app-store/marketing/sources/${name}.png`:`app-store/screenshots/iphone-67/${name}.png`);
const shots=[
 {id:'01-discover',title:'FIND YOUR<br>NEXT FAVORITE.',sub:'Fashion. Beauty. Home. All in one place.',screen:'home',style:'hero'},
 {id:'02-search',title:'ONE SEARCH.<br>MORE POSSIBILITIES.',sub:'Discover products across the brands you love.',screen:'searchResultsMixed',style:'search'},
 {id:'03-explore',title:'YOUR STYLE.<br>YOUR WAY TO SHOP.',sub:'Explore categories made for every kind of find.',screen:'bagsSubcategories',style:'browse'},
 {id:'04-detail',title:'TAKE A<br>CLOSER LOOK.',sub:'Explore the details. Find the one.',screen:'detail',style:'detail'},
 {id:'05-brands',title:'GREAT BRANDS.<br>NEW DISCOVERIES.',sub:'Meet your next favorite brand.',screen:'brands',style:'brands'},
 {id:'06-checkout',title:'FOUND IT?<br>MAKE IT YOURS.',sub:'Shop directly with each brand.',screen:'cart',style:'cart'},
 {id:'07-personal',title:'MAKE MARRACAT<br>YOUR OWN.',sub:'Your likes. Your history. Your kind of finds.',screen:'apple-account',style:'account'}
];
function crop(screen,x,y,w,h,dx,dy,dw,extra=''){
 const scale=dw/w;return `<div class="crop ${extra}" style="left:${dx}px;top:${dy}px;width:${dw}px;height:${h*scale}px"><img src="${source(screen)}" style="width:${1320*scale}px;left:${-x*scale}px;top:${-y*scale}px"></div>`;
}
function card(screen,x,y,w,angle=0){return `<div class="screen" style="left:${x}px;top:${y}px;width:${w}px;height:${w*2.04}px;transform:rotate(${angle}deg)"><img src="${source(screen)}" style="width:${w}px;top:${-w*.11}px"></div>`}
function content(s){switch(s.style){
case 'hero':return card('home',230,655,860)+crop('detail',114,596,1089,1089,-155,890,420,'behind')+crop('searchResultsMixed',42,1140,411,411,1090,1350,400,'behind')+crop('home',42,1356,556,785,-75,1905,500)+crop('home',665,1356,556,785,920,2120,485);
case 'search':return card(s.screen,285,660,750)+crop(s.screen,22,365,1276,720,86,965,1150)+crop(s.screen,22,1092,1276,537,170,1735,1150);
case 'browse':return card(s.screen,250,650,820)+crop(s.screen,30,1128,1260,1020,74,1335,1172);
case 'detail':return card(s.screen,270,655,780)+crop(s.screen,38,568,1240,1150,70,875,1180)+crop(s.screen,32,2040,1256,499,115,2100,1090);
case 'brands':return card(s.screen,270,650,780)+crop(s.screen,63,476,1190,905,62,1160,1196)+crop(s.screen,63,1381,1190,890,162,2115,1030);
case 'cart':return card(s.screen,250,645,820)+crop(s.screen,25,344,1265,226,77,945,1166)+crop(s.screen,26,610,1264,751,77,1230,1166);
case 'account':return card(s.screen,270,665,780)+crop(s.screen,28,664,1264,792,67,1120,1186)+crop(s.screen,26,1459,1268,366,170,1950,1024);
}}
function html(s){return `<!doctype html><meta charset="utf-8"><style>
*{box-sizing:border-box}html,body{margin:0;background:#111}body{width:1320px;height:2868px;overflow:hidden}
.stage{width:1320px;height:2868px;position:relative;overflow:hidden;background:radial-gradient(ellipse 105% 50% at 50% 89%,#c1c1c7 0%,#686970 36%,#303034 64%,#141415 85%,#09090a 100%)}
.stage:after{content:'';position:absolute;left:0;bottom:0;width:100%;height:160px;background:linear-gradient(transparent,rgba(12,12,13,.35));pointer-events:none;z-index:6}
.brand{position:absolute;top:107px;width:100%;text-align:center;color:#bcbcc2;font:500 32px Futura;letter-spacing:13px}
h1{position:absolute;top:200px;left:70px;width:1180px;margin:0;text-align:center;font:500 101px/1.14 Futura;letter-spacing:-2px;color:#fff;z-index:9}
.subtitle{position:absolute;top:476px;width:100%;text-align:center;font:400 38px/1.4 -apple-system,BlinkMacSystemFont,sans-serif;color:#d1d1d6;z-index:9}
.screen{position:absolute;overflow:hidden;border-radius:38px;background:black;box-shadow:0 24px 70px #000b,0 0 0 2px #64646d80;z-index:2}
.screen img,.crop img{position:absolute;max-width:none}
.crop{position:absolute;overflow:hidden;border-radius:28px;background:#1c1c1e;box-shadow:0 23px 65px #0008,0 0 0 2px #9b9ba340;z-index:4}
.behind{z-index:1;transform:rotate(-7deg);opacity:.92}
</style><div class="stage"><div class="brand">MARRACAT</div><h1>${s.title}</h1><div class="subtitle">${s.sub}</div>${content(s)}</div>`}
(async()=>{const browser=await chromium.launch({headless:true,channel:'chrome'});
for(const [dir,w,h] of [['iphone-67',1320,2868],['iphone-65',1284,2778]]){
 const page=await browser.newPage({viewport:{width:w,height:h},deviceScaleFactor:1});
 for(const s of shots){await page.setContent(html(s));await page.evaluate(({w,h})=>{document.querySelector('.stage').style.transform=`scale(${w/1320},${h/2868})`;document.querySelector('.stage').style.transformOrigin='top left';document.body.style.width=w+'px';document.body.style.height=h+'px';},{w,h});await page.evaluate(()=>document.fonts.ready);await page.waitForFunction(()=>[...document.images].every(i=>i.complete&&i.naturalWidth));await page.screenshot({path:path.join(__dirname,dir,s.id+'.png'),type:'png'});console.log(dir,s.id);}
 await page.close();}
const page=await browser.newPage({viewport:{width:1680,height:1100},deviceScaleFactor:1});let doc='<body style="margin:0;padding:32px;background:#181819;color:white;font:16px Futura"><div style="display:flex;gap:18px">';for(const s of shots)doc+=`<div><img style="width:216px;border-radius:12px" src="${image('app-store/marketing/iphone-67/'+s.id+'.png')}"><p>${s.id}</p></div>`;await page.setContent(doc+'</div></body>');await page.screenshot({path:path.join(__dirname,'overview.png'),clip:{x:0,y:0,width:1680,height:565}});await browser.close();
fs.writeFileSync(path.join(__dirname,'manifest.json'),JSON.stringify(shots,null,2)+'\n');})();

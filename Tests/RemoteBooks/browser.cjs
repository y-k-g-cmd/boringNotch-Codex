const {chromium}=require(process.env.PLAYWRIGHT_MODULE || 'playwright');
const {spawn}=require('node:child_process');
const assert=require('node:assert/strict');
const fs=require('node:fs');
const child=spawn(process.argv[2],[process.argv[3]],{stdio:['pipe','pipe','inherit']});
let browser;
(async()=>{
 const config=await new Promise((resolve,reject)=>{let text='';child.stdout.on('data',d=>{text+=d;if(text.includes('\n'))resolve(JSON.parse(text.split('\n')[0]))});child.once('error',reject)});
 assert.equal(config.state,'ready');
 const base='http://127.0.0.1:'+config.addresses[0].split(':').pop();
 browser=await chromium.launch({headless:true, args:['--no-proxy-server']});
 const context=await browser.newContext({viewport:{width:390,height:844},isMobile:true,hasTouch:true});
 const page=await context.newPage();let errors=[];page.on('pageerror',e=>errors.push(e.message));
 await page.goto(base);await page.locator('#pin').fill('00000000'===config.pin?'11111111':'00000000');await page.locator('.connect').click();await page.waitForFunction(()=>document.querySelector('#notice').textContent.includes('错误'));
 await page.locator('#pin').fill(config.pin);await page.locator('.connect').click();await page.locator('#next').waitFor({state:'visible'});
 for(const [id,label] of [['next','下一页'],['prev','上一页']]){await page.locator('#'+id).click();await page.waitForFunction(label=>document.querySelector('#notice').textContent.includes(label),label)}
 await page.reload();await page.locator('#next').waitFor({state:'visible'});
 const out=process.argv[4];fs.mkdirSync(out,{recursive:true});
 for(const [w,h] of [[390,844],[320,568],[844,390],[1440,900]]){
  await page.setViewportSize({width:w,height:h});
  assert(await page.evaluate(()=>document.documentElement.scrollWidth<=innerWidth));
  const box=await page.locator('#next').boundingBox();assert(box.height>=100);
  await page.screenshot({path:out+`/phone-${w}x${h}.png`,fullPage:true});
 }
 await page.evaluate(()=>sessionStorage.clear());await page.goto('about:blank');await page.goto(base+'/#'+config.token);await page.locator('#next').waitFor({state:'visible'});assert(!page.url().includes('#'));
 await context.setOffline(true);await page.locator('#next').click();await page.waitForFunction(()=>document.querySelector('#notice').textContent.includes('中断'));await context.setOffline(false);
 assert.deepEqual(errors,[]);console.log('PASS: native server + mobile browser pairing, prev/next, reload, fragment cleanup, offline error and four viewport layouts');
})().catch(e=>{console.error(e.message);process.exitCode=1}).finally(async()=>{if(browser)await browser.close();child.kill()});

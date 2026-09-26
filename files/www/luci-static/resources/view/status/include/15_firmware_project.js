'use strict';
'require baseclass';
'require rpc';
'require ui';

var projectUrl = 'https://github.com/fu5502/immortalwrt-custom-firmware';

var callGetFirmwareVersion = rpc.declare({
	object: 'luci',
	method: 'getFirmwareVersion',
	expect: { version: '' }
});

var callGetFirmwareUpdateInfo = rpc.declare({
	object: 'luci',
	method: 'getFirmwareUpdateInfo',
	expect: { result: {} }
});

var callStartFirmwareUpdate = rpc.declare({
	object: 'luci',
	method: 'startFirmwareUpdate',
	expect: { result: '' }
});

var callGetFirmwareUpdateLog = rpc.declare({
	object: 'luci',
	method: 'getFirmwareUpdateLog',
	expect: {}
});

function externalLink(url, label) {
	return E('a', {
		'href': url,
		'target': '_blank',
		'rel': 'noopener noreferrer'
	}, [label]);
}

function estimateProgressFromLog(logText, logStatus) {
	if (logStatus === 'rebooting') {
		return { percent: 100, stage: '固件已成功刷入磁盘！', detail: '系统正在重新启动，请稍候恢复访问...' };
	}
	if (logStatus === 'failed') {
		return { percent: 100, stage: '固件升级失败', detail: '升级过程遇到错误，请查看下方日志详情' };
	}
	if (!logText) {
		return { percent: 5, stage: '正在启动升级任务...', detail: '正在初始化任务...' };
	}

	if (logText.indexOf('正在执行无损保留配置刷入') !== -1 || logText.indexOf('sysupgrade -v') !== -1) {
		return { percent: 92, stage: '正在刷入磁盘 (sysupgrade)...', detail: '正在写入磁盘并保留所有配置，请勿断电...' };
	}
	if (logText.indexOf('正在暂停代理服务') !== -1) {
		return { percent: 85, stage: '正在封存配置数据库...', detail: '安全暂停高频服务，保护配置完整性...' };
	}
	if (logText.indexOf('兼容性测试通过') !== -1) {
		return { percent: 80, stage: '系统兼容性仿真测试通过', detail: '准备进行刷机操作...' };
	}
	if (logText.indexOf('正在执行 sysupgrade -T') !== -1) {
		return { percent: 75, stage: '正在进行系统兼容性仿真测试...', detail: '校验固件架构与平台兼容性...' };
	}
	if (logText.indexOf('SHA256 校验通过') !== -1) {
		return { percent: 70, stage: 'SHA256 校验通过', detail: '固件完整性校验成功' };
	}
	if (logText.indexOf('正在校验 SHA256') !== -1) {
		return { percent: 65, stage: '正在校验 SHA256 完整性...', detail: '比对校验和，确保文件无损坏...' };
	}
	if (logText.indexOf('跳过重复下载') !== -1) {
		return { percent: 62, stage: '固件已就绪', detail: '本地已存在校验一致的固件镜像' };
	}
	if (logText.indexOf('SHA256校验文件') !== -1) {
		return { percent: 58, stage: '正在下载校验文件...', detail: '获取 SHA256SUMS.txt...' };
	}
	if (logText.indexOf('正在下载') !== -1 || logText.indexOf('尝试镜像通道下载') !== -1) {
		return { percent: 35, stage: '正在下载固件镜像...', detail: '从 GitHub / 镜像源拉取固件中...' };
	}
	if (logText.indexOf('目标版本:') !== -1) {
		return { percent: 10, stage: '已确认目标版本', detail: '准备下载固件与校验文件...' };
	}
	return { percent: 6, stage: '正在检查最新版本...', detail: '获取 GitHub 最新 Release 信息...' };
}

function createProgressBar() {
	var stageLabel = E('span', {
		'style': 'font-size: 13px; font-weight: 600; color: inherit;'
	}, ['正在准备升级...']);

	var percentBadge = E('span', {
		'style': 'font-size: 14px; font-weight: bold; color: #10b981; font-family: monospace;'
	}, ['0%']);

	var headerRow = E('div', {
		'style': 'display: flex; justify-content: space-between; align-items: center; margin-bottom: 8px;'
	}, [stageLabel, percentBadge]);

	var barInner = E('div', {
		'style': 'width: 0%; height: 100%; background: linear-gradient(90deg, #10b981, #059669); border-radius: 9px; transition: width 0.3s ease, background 0.3s ease; position: relative; box-shadow: 0 0 8px rgba(16, 185, 129, 0.4);'
	}, []);

	var barTrack = E('div', {
		'style': 'width: 100%; height: 16px; background: rgba(125, 125, 125, 0.2); border-radius: 9px; overflow: hidden; position: relative; box-shadow: inset 0 1px 2px rgba(0, 0, 0, 0.15);'
	}, [barInner]);

	var detailText = E('div', {
		'style': 'font-size: 12px; opacity: 0.75; margin-top: 6px; min-height: 18px; line-height: 18px;'
	}, ['正在初始化升级任务，请保持电源稳定...']);

	var container = E('div', {
		'style': 'display: none; margin: 15px 0; padding: 14px; background: rgba(125, 125, 125, 0.06); border-radius: 8px; border: 1px solid rgba(125, 125, 125, 0.15);'
	}, [headerRow, barTrack, detailText]);

	return {
		container: container,
		update: function(pct, stage, detail, status) {
			pct = Math.max(0, Math.min(100, Math.round(pct || 0)));
			barInner.style.width = pct + '%';
			percentBadge.textContent = pct + '%';

			if (stage) stageLabel.textContent = stage;
			if (detail) detailText.textContent = detail;

			if (status === 'failed') {
				barInner.style.background = '#ef4444';
				barInner.style.boxShadow = '0 0 8px rgba(239, 68, 68, 0.4)';
				percentBadge.style.color = '#ef4444';
			} else if (status === 'rebooting' || pct >= 100) {
				barInner.style.background = 'linear-gradient(90deg, #3b82f6, #10b981)';
				barInner.style.boxShadow = '0 0 8px rgba(59, 130, 246, 0.4)';
				percentBadge.style.color = '#3b82f6';
			} else {
				barInner.style.background = 'linear-gradient(90deg, #10b981, #059669)';
				barInner.style.boxShadow = '0 0 8px rgba(16, 185, 129, 0.4)';
				percentBadge.style.color = '#10b981';
			}
		},
		show: function() {
			container.style.display = 'block';
		},
		hide: function() {
			container.style.display = 'none';
		}
	};
}

return baseclass.extend({
	title: '自定义固件与在线更新',

	load: function() {
		return Promise.all([
			L.resolveDefault(callGetFirmwareVersion(), '-')
		]);
	},

	render: function(data) {
		var rawVersion = data?.[0];
		var initialVersion = (typeof(rawVersion) === 'string' && rawVersion.trim())
			? rawVersion.trim()
			: ((rawVersion && typeof(rawVersion) === 'object' && rawVersion.version)
				? String(rawVersion.version).trim()
				: '-');
		var statusText = E('span', { 'class': 'badge' }, ['未检查']);
		var actionContainer = E('span', {}, []);
		var currentTagTd = E('td', { 'class': 'td left' }, [initialVersion]);
		var latestTagTd = E('td', { 'class': 'td left' }, ['-']);

		var checkBtn = E('button', {
			'class': 'btn cbi-button-action',
			'click': function(ev) {
				ev.preventDefault();
				checkBtn.disabled = true;
				checkBtn.textContent = '正在检查最新版本...';

				callGetFirmwareUpdateInfo().then(function(res) {
					checkBtn.disabled = false;
					checkBtn.textContent = '重新检查';

					if (!res || !res.latest_tag) {
						statusText.textContent = '检查失败，请检查网络';
						return;
					}

					currentTagTd.textContent = res.current_tag || initialVersion;
					latestTagTd.innerHTML = '';
					latestTagTd.appendChild(externalLink(res.release_url, res.latest_tag));

					actionContainer.innerHTML = '';

					var upgradeBtn = E('button', {
						'class': 'btn cbi-button-' + (res.has_update ? 'positive' : 'neutral'),
						'style': 'margin-left: 8px;',
						'click': function(ev2) {
							ev2.preventDefault();
							showUpgradeConfirmModal(res);
						}
					}, [res.has_update ? '一键无损升级' : '重新刷写最新版']);

					actionContainer.appendChild(upgradeBtn);

					if (res.has_update) {
						statusText.className = 'badge warning';
						statusText.textContent = '发现新版本 (' + (res.published_at ? res.published_at.slice(0, 10) : '') + ')';
					} else {
						statusText.className = 'badge success';
						statusText.textContent = '已是最新固件';
					}
				}).catch(function(err) {
					checkBtn.disabled = false;
					checkBtn.textContent = '检查更新';
					statusText.textContent = '请求出错: ' + (err.message || err);
				});
			}
		}, ['检查更新']);

		function showUpgradeConfirmModal(info) {
			ui.showModal('确认固件无损在线升级', [
				E('p', {}, [
					'系统将自动从 GitHub 下载最新固件（含 Open-Box、OpenClash、PassWall 等），',
					E('strong', {}, '并 100% 保留您当前的网络 IP、代理节点与所有配置数据')
				]),
				E('p', { 'class': 'alert-message warning' }, [
					'⚠️ 升级过程中请勿断电或关机。刷写完成后路由器将自动重启（约需 1~2 分钟）。'
				]),
				E('div', { 'class': 'right' }, [
					E('button', {
						'class': 'btn',
						'click': ui.hideModal
					}, ['取消']),
					' ',
					E('button', {
						'class': 'btn cbi-button-positive',
						'click': function() {
							startUpgradeProcess(info);
						}
					}, ['确认开始升级'])
				])
			]);
		}

		function startUpgradeProcess(info) {
			var progressBar = createProgressBar();
			progressBar.show();
			progressBar.update(5, '正在启动升级任务...', '正在连接后台任务引擎...');

			var logPre = E('pre', {
				'style': 'max-height: 220px; overflow-y: auto; background: #181818; color: #00ff66; padding: 12px; border-radius: 4px; font-family: monospace; font-size: 12px; margin-top: 10px;'
			}, ['正在启动升级任务...\n']);

			var tipP = E('p', { 'style': 'font-weight: 500; margin-bottom: 5px;' }, ['⏳ 升级进行中，请勿断电或刷新页面...']);

			ui.showModal('固件在线升级进度', [
				tipP,
				progressBar.container,
				logPre
			]);

			callStartFirmwareUpdate().then(function() {
				var pollTimer = window.setInterval(function() {
					callGetFirmwareUpdateLog().then(function(logData) {
						if (logData && logData.log) {
							logPre.textContent = logData.log;
							logPre.scrollTop = logPre.scrollHeight;
						}

						var pct = logData ? logData.percent : null;
						var stage = logData ? logData.stage : null;
						var detail = logData ? logData.detail : null;
						var status = logData ? logData.status : 'running';

						if (pct === undefined || pct === null || pct === 0) {
							var est = estimateProgressFromLog(logData ? logData.log : '', status);
							pct = est.percent;
							stage = est.stage;
							detail = est.detail;
						}

						progressBar.update(pct, stage, detail, status);

						if (status === 'rebooting') {
							window.clearInterval(pollTimer);
							progressBar.update(100, '固件已成功刷入磁盘！', '路由器正在重新启动，预计 60 秒后恢复访问...', 'rebooting');
							tipP.textContent = '✅ 固件已成功写入！路由器正在重启，系统将在 60 秒后自动刷新...';
							tipP.style.color = '#00aaff';
							var countdown = 60;
							var cdTimer = window.setInterval(function() {
								countdown--;
								if (countdown <= 0) {
									window.clearInterval(cdTimer);
									window.location.reload();
								} else {
									tipP.textContent = '✅ 固件已成功写入！路由器正在重启，' + countdown + ' 秒后自动刷新...';
								}
							}, 1000);
						} else if (status === 'failed') {
							window.clearInterval(pollTimer);
							progressBar.update(100, '固件升级失败', detail || '升级过程遇到错误，请查看下方日志详情', 'failed');
							tipP.textContent = '❌ 升级失败，请查看下方日志原因。';
							tipP.style.color = 'red';
						}
					}).catch(function() {
						window.clearInterval(pollTimer);
						progressBar.update(100, '连接已断开（系统正在重启）', '路由器正在重新启动，请稍候刷新...', 'rebooting');
						tipP.textContent = '✅ 连接已断开，路由器正在重启，60 秒后自动刷新...';
						window.setTimeout(function() {
							window.location.reload();
						}, 60000);
					});
				}, 1000);
			}).catch(function(e) {
				progressBar.update(100, '启动失败', e.message || String(e), 'failed');
				tipP.textContent = '启动失败: ' + (e.message || e);
			});
		}

		return E('table', { 'class': 'table' }, [
			E('tr', { 'class': 'tr' }, [
				E('td', { 'class': 'td left', 'width': '33%' }, ['项目主页']),
				E('td', { 'class': 'td left' }, [
					externalLink(projectUrl, 'fu5502/immortalwrt-custom-firmware')
				])
			]),
			E('tr', { 'class': 'tr' }, [
				E('td', { 'class': 'td left', 'width': '33%' }, ['当前固件版本']),
				currentTagTd
			]),
			E('tr', { 'class': 'tr' }, [
				E('td', { 'class': 'td left', 'width': '33%' }, ['最新发布版本']),
				latestTagTd
			]),
			E('tr', { 'class': 'tr' }, [
				E('td', { 'class': 'td left', 'width': '33%' }, ['在线固件更新']),
				E('td', { 'class': 'td left' }, [
					statusText,
					' ',
					checkBtn,
					actionContainer
				])
			])
		]);
	}
});

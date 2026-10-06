const modules = {
  limit: {
    code: "01",
    title: "端口限速",
    description: "为服务端口创建独立的出口带宽规则。",
    message: "等待输入。按 Enter 打开端口限速。",
  },
  inspect: {
    code: "02",
    title: "系统信息",
    description: "查看网卡、内核、队列和当前规则的运行状态。",
    message: "系统信息模块已就绪。",
  },
  service: {
    code: "03",
    title: "服务管理",
    description: "管理限速服务的启动、停止和开机自启。",
    message: "服务管理模块已就绪。",
  },
  firewall: {
    code: "04",
    title: "防火墙规则",
    description: "为后续的端口访问策略预留统一入口。",
    message: "防火墙模块已预留。",
  },
  logs: {
    code: "05",
    title: "日志中心",
    description: "集中查看规则应用结果和最近的系统事件。",
    message: "日志中心模块已就绪。",
  },
  update: {
    code: "06",
    title: "脚本更新",
    description: "从远程仓库拉取最新版本并同步服务器文件。",
    message: "更新模块已就绪。",
  },
};

const menuItems = [...document.querySelectorAll(".menu-item")];
const input = document.querySelector("#commandInput");
const message = document.querySelector("#consoleMessage");
const moduleCode = document.querySelector("#moduleCode");
const moduleTitle = document.querySelector("#moduleTitle");
const moduleDescription = document.querySelector("#moduleDescription");
const logClock = document.querySelector("#logClock");
const logEntries = document.querySelector("#logEntries");

let activeIndex = 0;

function now() {
  return new Intl.DateTimeFormat("zh-CN", {
    hour: "2-digit",
    minute: "2-digit",
    second: "2-digit",
    hour12: false,
  }).format(new Date());
}

function addLog(type, text) {
  const entry = document.createElement("p");
  const time = document.createElement("time");
  const state = document.createElement("span");
  time.textContent = now();
  state.className = type === "OK" ? "log-ok" : "log-info";
  state.textContent = type;
  entry.append(time, state, document.createTextNode(text));
  logEntries.prepend(entry);
  while (logEntries.children.length > 4) {
    logEntries.lastElementChild.remove();
  }
}

function selectModule(key, announce = true) {
  const selected = modules[key];
  if (!selected) return;
  activeIndex = menuItems.findIndex((item) => item.dataset.module === key);
  menuItems.forEach((item) => item.classList.toggle("is-active", item.dataset.module === key));
  moduleCode.textContent = selected.code;
  moduleTitle.textContent = selected.title;
  moduleDescription.textContent = selected.description;
  if (announce) {
    message.textContent = selected.message;
    addLog("INFO", `${selected.title} selected`);
  }
}

function selectByNumber(value) {
  const selected = menuItems.find((item) => item.querySelector(".menu-index").textContent.startsWith(value));
  if (selected) {
    selectModule(selected.dataset.module);
    return true;
  }
  return false;
}

menuItems.forEach((item) => {
  item.addEventListener("click", () => selectModule(item.dataset.module));
});

document.querySelectorAll("[data-action]").forEach((button) => {
  button.addEventListener("click", () => {
    const action = button.dataset.action;
    if (action === "refresh") {
      message.textContent = "状态已刷新。当前规则仍处于 READY。";
      addLog("OK", "status refreshed");
    }
    if (action === "exit") {
      message.textContent = "浏览器控制台不会关闭，输入编号可继续操作。";
      addLog("INFO", "exit requested");
    }
    if (action === "apply") {
      message.textContent = "演示模式：规则应用入口已触发。";
      addLog("OK", "apply request queued");
    }
    if (action === "edit") {
      input.focus();
      message.textContent = "输入新的模块编号，参数编辑器将在下一版接入。";
      addLog("INFO", "editor placeholder opened");
    }
  });
});

input.addEventListener("keydown", (event) => {
  if (event.key === "Enter") {
    const value = input.value.trim();
    if (value === "00") {
      document.querySelector('[data-action="refresh"]').click();
    } else if (value === "0") {
      document.querySelector('[data-action="exit"]').click();
    } else if (!selectByNumber(value.padStart(2, "0") + ".")) {
      message.textContent = `未找到模块 ${value || "?"}。请输入 01—06、00 或 0。`;
      addLog("INFO", "unknown command");
    }
    input.value = "";
  }
  if (event.key === "ArrowDown" || event.key === "ArrowUp") {
    event.preventDefault();
    const direction = event.key === "ArrowDown" ? 1 : -1;
    activeIndex = (activeIndex + direction + menuItems.length) % menuItems.length;
    selectModule(menuItems[activeIndex].dataset.module);
  }
});

input.addEventListener("input", () => {
  input.value = input.value.replace(/[^0-9]/g, "");
});

setInterval(() => {
  logClock.textContent = now();
}, 1000);

logClock.textContent = now();
input.focus();

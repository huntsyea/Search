// What a panel asks first: the tab in front of its own window.
chrome.tabs.query({ active: true, currentWindow: true }).then((tabs) => {
  const tab = tabs[0];
  document.getElementById("tab").textContent = tab ? "Front tab: " + tab.title + " — " + tab.url : "No front tab";
  window.frontTab = tab ? tab.url : "";
}, (error) => {
  document.getElementById("tab").textContent = "Error: " + error.message;
  window.frontTab = "error: " + error.message;
});

import { createApp } from "vue";
import router from "./router";
import App from "./App.vue";
import "./assets/base.css";
import "@dafcoe/vue-notification/dist/vue-notification.css";
import "vue-toast-notification/dist/theme-sugar.css";
import ToastPlugin from "vue-toast-notification";
import "flowbite";
import "tw-elements";

// @ts-ignore
import VueNotificationList from "@dafcoe/vue-notification";

import { OhVueIcon, addIcons } from "oh-vue-icons";

import { MdKeyboardarrowdownRound, IoCloseOutline } from "oh-vue-icons/icons";

addIcons(MdKeyboardarrowdownRound, IoCloseOutline);
const app = createApp(App).component("v-icon", OhVueIcon);
app.use(VueNotificationList);
app.use(router);
app.use(ToastPlugin);
app.mount("#app");

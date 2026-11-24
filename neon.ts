import {defineConfig} from '@neon/config/v1';
// Data API preserves the existing PostgREST application protocol.
export default defineConfig({auth:true,dataApi:true});
